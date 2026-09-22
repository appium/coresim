#include "av_recording.h"

#include <atomic>
#include <mutex>
#include <vector>

#include "audio_encoder.h"
#include "monotonic_clock.h"
#include "nserror_bridge.h"
#include "sim_audio_tap.h"

namespace coresim {

namespace {

NSString* const kAVRecordingErrorDomain = @"com.appium.coresim.AVRecording";

NSError* MakeError(NSInteger code, NSString* message) {
  return [NSError errorWithDomain:kAVRecordingErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

constexpr size_t kMaxPendingAudioSamples = 500;  // a few seconds of AAC packets — see HandleAudioSample

}  // namespace

class AVRecordingSession::Impl {
 public:
  Impl(id device, NSString* udid, VideoEncoderOptions videoOptions, NSString* outputFile, bool captureAudio)
      : device_(device),
        udid_(udid),
        videoOptions_(videoOptions),
        outputFile_(outputFile),
        captureAudio_(captureAudio) {}

  ~Impl() { TearDownIfNeeded(); }

  void Start(std::function<void()> onFirstSample, std::function<void(NSError*)> onError, std::function<void()> onEnd) {
    onFirstSample_ = std::move(onFirstSample);
    onError_ = std::move(onError);
    onEnd_ = std::move(onEnd);
    clockOrigin_ = MonotonicSeconds();

    [[NSFileManager defaultManager] removeItemAtPath:outputFile_ error:nil];
    NSError* writerError = nil;
    writer_ = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:outputFile_]
                                       fileType:AVFileTypeMPEG4
                                          error:&writerError];
    if (writer_ == nil) {
      throw NSErrorException(writerError ?: MakeError(1, @"Failed to create an AVAssetWriter"));
    }

    try {
      if (captureAudio_) {
        audioTap_ = std::make_unique<AudioTapSession>(
            udid_, [this](const AudioBufferList* data, const AudioTimeStamp* time) { HandleAudioPCM(data, time); },
            [this](NSError* error) {
              // A single failed process-list refresh doesn't mean the tap stopped — see this
              // code's own doc comment. Every other onError code does, and is fatal here.
              if ([error.domain isEqualToString:kAudioTapErrorDomain] &&
                  error.code == kAudioTapNonFatalProcessListRefreshErrorCode) {
                return;
              }
              Fail(error, /*fromVideo=*/false);
            },
            [] {});
        audioTap_->Start();

        // audioTap_->Start() can invoke HandleAudioPCM (on the tap's own queue) before this
        // function returns — audioEncoder_ is written here under mutex_, and HandleAudioPCM reads
        // it under the same lock, so that racing read can never observe a partially-constructed
        // pointer; it just sees "not ready yet" and skips the buffer.
        auto encoder = std::make_unique<AudioEncoder>(
            audioTap_->Format(), [this](CMSampleBufferRef sampleBuffer) { HandleAudioSample(sampleBuffer); },
            &clockOrigin_);
        {
          std::lock_guard<std::mutex> lock(mutex_);
          audioEncoder_ = std::move(encoder);
        }
        // Audio's format is known immediately (unlike video's, learned from its first sample), so
        // its input can be added to the writer right away — well before startWriting is called.
        audioInput_ = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                         outputSettings:nil
                                                       sourceFormatHint:audioEncoder_->OutputFormatDescription()];
        audioInput_.expectsMediaDataInRealTime = YES;
        [writer_ addInput:audioInput_];
      }

      videoEncoder_ = std::make_unique<VideoFrameEncoder>(
          device_, videoOptions_, [this](CMSampleBufferRef sampleBuffer) { HandleVideoSample(sampleBuffer); },
          [this](NSError* error) { Fail(error, /*fromVideo=*/true); }, [] {}, &clockOrigin_);
      videoEncoder_->Start();
    } catch (...) {
      TearDownIfNeeded();
      throw;
    }
  }

  // Must be fully idempotent, including concurrently and regardless of the first call's outcome:
  // besides ordinary caller retries, the env cleanup hook (coresim.mm) also unconditionally calls
  // Stop() on every still-registered session — including one the caller already stopped
  // successfully moments earlier but whose NativeAVRecording JS wrapper GC hasn't yet deregistered
  // (see CLAUDE.md's ThreadSafeFunction-release ordering note for why the hook must call it
  // unconditionally at all). A second real attempt to finalize an AVAssetWriter that's already
  // `.completed` throws an uncaught NSException and aborts the whole process — so only the FIRST
  // call ever touches the writer/encoders; every later call (or one arriving while the first is
  // still in flight) just replays that same eventual outcome instead.
  void Stop(std::function<void(NSError*)> onFinished) {
    bool isFirstCall;
    bool resultReady;
    NSError* resultError = nil;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      isFirstCall = !stopped_;
      stopped_ = true;
      resultReady = stopResultReady_;
      resultError = stopResultError_;
      if (!isFirstCall && !resultReady) {
        pendingStopCallbacks_.push_back(std::move(onFinished));
        return;
      }
    }
    if (!isFirstCall) {
      if (onFinished) {
        onFinished(resultError);
      }
      return;
    }

    // Blocks until each has fully torn down — only then is it safe to finalize the writer without
    // racing a further HandleVideoSample/HandleAudioSample call. Also the point past which no new
    // Fail() can ever start (both encoders' onError channels are now silenced), which is what
    // makes the stopResultReady_ check right below race-free: a Fail() concurrent with the Stop()
    // calls above (e.g. from the audio tap's own poll timer, mid-teardown) is guaranteed to have
    // either not started yet, or to have already fully completed — including its own
    // [writer_ cancelWriting] — by the time these two calls return (each one's own Stop()
    // documents blocking/draining until any in-flight callback, and thus any Fail() it triggered,
    // has finished).
    if (videoEncoder_) {
      videoEncoder_->Stop();
    }
    if (audioTap_) {
      audioTap_->Stop();
    }

    bool started;
    bool alreadyFailed;
    NSError* failedError = nil;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      started = writerStarted_;
      alreadyFailed = stopResultReady_;
      failedError = stopResultError_;
      ClearPendingAudioLocked();
    }
    if (alreadyFailed) {
      // A concurrent Fail() already recorded the session's one true outcome (and, if the writer
      // had started, already cancelled it) while the Stop() calls above were still draining —
      // replay that same outcome instead of touching the writer again: it may already be
      // `.cancelled`, and finishWritingWithCompletionHandler on that state throws an uncaught
      // NSException that aborts the whole process.
      if (onFinished) {
        onFinished(failedError);
      }
      FireEndOnce();
      return;
    }
    if (!started) {
      FinishStop(MakeError(2, @"No audio or video was captured before the recording was stopped"),
                 std::move(onFinished));
      return;
    }
    [videoInput_ markAsFinished];
    [audioInput_ markAsFinished];  // no-op if `captureAudio_` was never set (audioInput_ stays nil)
    AVAssetWriter* writer = writer_;
    [writer finishWritingWithCompletionHandler:^{
      NSError* finishError = (writer.status == AVAssetWriterStatusCompleted) ? nil : writer.error;
      FinishStop(finishError, std::move(onFinished));
    }];
  }

 private:
  void HandleVideoSample(CMSampleBufferRef sampleBuffer) {
    NSError* writingError = nil;
    bool justStarted = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_) {
        return;
      }
      if (!writerStarted_) {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        videoInput_ = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                         outputSettings:nil
                                                       sourceFormatHint:format];
        videoInput_.expectsMediaDataInRealTime = YES;
        [writer_ addInput:videoInput_];
        if ([writer_ startWriting]) {
          [writer_ startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
          writerStarted_ = true;
          justStarted = true;
          AppendVideoLocked(sampleBuffer);
          for (CMSampleBufferRef pending : pendingAudio_) {
            AppendAudioLocked(pending);
            CFRelease(pending);
          }
          pendingAudio_.clear();
        } else {
          writingError = writer_.error ?: MakeError(3, @"AVAssetWriter startWriting failed");
        }
      } else {
        AppendVideoLocked(sampleBuffer);
      }
    }
    if (writingError != nil) {
      // Detected while handling a video callback — see Fail()'s doc comment for why this can only
      // safely stop the audio side directly from here, not video's own encoder.
      Fail(writingError, /*fromVideo=*/true);
      return;
    }
    if (justStarted) {
      FireFirstSampleOnce();
    }
  }

  void HandleAudioSample(CMSampleBufferRef sampleBuffer) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) {
      return;
    }
    if (!writerStarted_) {
      // Buffered until video's first sample establishes the writer's format/session (see
      // HandleVideoSample) — capped so a display that never resolves can't grow this unboundedly.
      CFRetain(sampleBuffer);
      pendingAudio_.push_back(sampleBuffer);
      if (pendingAudio_.size() > kMaxPendingAudioSamples) {
        CFRelease(pendingAudio_.front());
        pendingAudio_.erase(pendingAudio_.begin());
      }
      return;
    }
    AppendAudioLocked(sampleBuffer);
  }

  // Runs on AudioTapSession's own serial queue (see its Start() call site's comment above) —
  // audioEncoder_ is only ever read/written under mutex_, so a racing HandleAudioPCM/Start() pair
  // can't observe a partially-constructed pointer (see Start()'s own comment). If EncodePCM
  // throws, it's intentionally left to propagate out of here: AudioTapSession::HandleBuffer (this
  // callback's own caller) catches it, reports it via the onError callback below (-> Fail()), and
  // safely stops itself — see sim_audio_tap.h's onBuffer doc comment for why this method must
  // never try to stop audioTap_ itself (it's running on audioTap_'s own queue — would deadlock).
  void HandleAudioPCM(const AudioBufferList* data, const AudioTimeStamp* time) {
    AudioEncoder* encoder;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_) {
        return;
      }
      encoder = audioEncoder_.get();
    }
    if (encoder != nullptr) {
      encoder->EncodePCM(data, time);
    }
  }

  // Caller holds mutex_.
  void AppendVideoLocked(CMSampleBufferRef sampleBuffer) {
    if (videoInput_.isReadyForMoreMediaData) {
      [videoInput_ appendSampleBuffer:sampleBuffer];
    }
  }

  // Caller holds mutex_.
  void AppendAudioLocked(CMSampleBufferRef sampleBuffer) {
    if (audioInput_.isReadyForMoreMediaData) {
      [audioInput_ appendSampleBuffer:sampleBuffer];
    }
  }

  // Caller holds mutex_.
  void ClearPendingAudioLocked() {
    for (CMSampleBufferRef pending : pendingAudio_) {
      CFRelease(pending);
    }
    pendingAudio_.clear();
  }

  void FireFirstSampleOnce() {
    if (!firstSampleFired_.exchange(true)) {
      if (onFirstSample_) {
        onFirstSample_();
      }
    }
  }

  void FireEndOnce() {
    if (!endFired_.exchange(true)) {
      if (onEnd_) {
        onEnd_();
      }
    }
  }

  // Caller holds mutex_. Records the session's single, final outcome the first time it's called
  // (from either FailLocked or Stop()'s own completion below) — a no-op on any later call, so
  // `stopResultError_` always reflects whichever happened first. Returns any Stop() calls that
  // arrived while the outcome was still unknown and were queued (see Stop()) waiting for it —
  // caller must invoke each with `error`, unlocked (they're arbitrary caller callbacks).
  std::vector<std::function<void(NSError*)>> RecordResultLocked(NSError* error) {
    if (stopResultReady_) {
      return {};
    }
    stopResultReady_ = true;
    stopResultError_ = error;
    std::vector<std::function<void(NSError*)>> pending;
    pending.swap(pendingStopCallbacks_);
    return pending;
  }

  // Caller holds mutex_. Returns any queued Stop() calls to flush (see RecordResultLocked).
  std::vector<std::function<void(NSError*)>> FailLocked(NSError* error) {
    if (stopResultReady_) {
      return {};  // already resolved (a prior Fail() or Stop() completion)
    }
    stopped_ = true;
    if (writerStarted_) {
      [writer_ cancelWriting];
    }
    ClearPendingAudioLocked();
    auto pending = RecordResultLocked(error);
    if (onError_) {
      onError_(error);
    }
    return pending;
  }

  // Called from either encoder's onError, or from HandleVideoSample on a writer-level failure —
  // NOT holding mutex_ (would risk deadlocking against that same encoder's own queue if it's
  // mid-callback elsewhere, see AppendVideoLocked/AppendAudioLocked's callers). Stops the OTHER
  // (still-running) encoder synchronously — the one whose callback we're currently inside is
  // already tearing itself down internally right after this callback returns (its own error
  // path), and calling its own blocking Stop() from within its own callback would deadlock.
  void Fail(NSError* error, bool fromVideo) {
    if (fromVideo) {
      if (audioTap_) {
        audioTap_->Stop();
      }
    } else {
      if (videoEncoder_) {
        videoEncoder_->Stop();
      }
    }
    std::vector<std::function<void(NSError*)>> pending;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pending = FailLocked(error);
    }
    for (auto& callback : pending) {
      if (callback) {
        callback(error);
      }
    }
    FireEndOnce();
  }

  // The single point where a real (first-ever) Stop() attempt's outcome becomes known — records
  // it, replies to `onFinished` and any callers that arrived while it was still in flight, then
  // fires onEnd_. Never called a second time for the same session (see Stop()'s own guard).
  void FinishStop(NSError* error, std::function<void(NSError*)> onFinished) {
    std::vector<std::function<void(NSError*)>> pending;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pending = RecordResultLocked(error);
    }
    if (onFinished) {
      onFinished(error);
    }
    for (auto& callback : pending) {
      if (callback) {
        callback(error);
      }
    }
    FireEndOnce();
  }

  // Best-effort, synchronous cleanup for the destructor path (Start() throwing partway through,
  // or the session being destroyed without an explicit Stop()) — no completion callback, unlike
  // the public Stop().
  void TearDownIfNeeded() {
    if (videoEncoder_) {
      videoEncoder_->Stop();
    }
    if (audioTap_) {
      audioTap_->Stop();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (writerStarted_ && writer_ != nil) {
      [writer_ cancelWriting];
    }
    ClearPendingAudioLocked();
  }

  id device_;
  NSString* udid_;
  VideoEncoderOptions videoOptions_;
  NSString* outputFile_;
  bool captureAudio_;

  std::function<void()> onFirstSample_;
  std::function<void(NSError*)> onError_;
  std::function<void()> onEnd_;

  double clockOrigin_ = 0;
  std::unique_ptr<VideoFrameEncoder> videoEncoder_;
  std::unique_ptr<AudioTapSession> audioTap_;
  std::unique_ptr<AudioEncoder> audioEncoder_;

  AVAssetWriter* writer_ = nil;
  AVAssetWriterInput* videoInput_ = nil;
  AVAssetWriterInput* audioInput_ = nil;

  std::mutex mutex_;
  bool writerStarted_ = false;
  bool stopped_ = false;  // true from the first Stop() (or Fail()) call onward
  bool stopResultReady_ = false;
  NSError* stopResultError_ = nil;
  std::vector<std::function<void(NSError*)>> pendingStopCallbacks_;  // Stop() calls awaiting stopResultReady_
  std::vector<CMSampleBufferRef> pendingAudio_;
  std::atomic<bool> firstSampleFired_{false};
  std::atomic<bool> endFired_{false};
};

AVRecordingSession::AVRecordingSession(id device, NSString* udid, VideoEncoderOptions videoOptions,
                                       NSString* outputFile, bool captureAudio)
    : impl_(std::make_unique<Impl>(device, udid, videoOptions, outputFile, captureAudio)) {}

AVRecordingSession::~AVRecordingSession() = default;

void AVRecordingSession::Start(std::function<void()> onFirstSample, std::function<void(NSError*)> onError,
                               std::function<void()> onEnd) {
  impl_->Start(std::move(onFirstSample), std::move(onError), std::move(onEnd));
}

void AVRecordingSession::Stop(std::function<void(NSError*)> onFinished) { impl_->Stop(std::move(onFinished)); }

}  // namespace coresim
