#include "av_stream.h"

#include <atomic>
#include <mutex>

#include "audio_encoder.h"
#include "monotonic_clock.h"
#include "sim_audio_tap.h"

namespace coresim {

class AVStreamSession::Impl {
 public:
  Impl(id device, NSString* udid, VideoEncoderOptions videoOptions, std::function<void(AVAccessUnit)> onAccessUnit,
       std::function<void(NSError*)> onError, std::function<void()> onEnd)
      : device_(device),
        udid_(udid),
        videoOptions_(videoOptions),
        onAccessUnit_(std::move(onAccessUnit)),
        onError_(std::move(onError)),
        onEnd_(std::move(onEnd)) {}

  ~Impl() { StopInternal(); }

  void Start() {
    clockOrigin_ = MonotonicSeconds();
    running_ = true;
    try {
      audioTap_ = std::make_unique<AudioTapSession>(
          udid_, [this](const AudioBufferList* data, const AudioTimeStamp* time) { HandleAudioPCM(data, time); },
          [this](NSError* error) {
            // A single failed process-list refresh doesn't mean the tap stopped — see this code's
            // own doc comment (sim_audio_tap.h). Every other onError code does, and is fatal here.
            if ([error.domain isEqualToString:kAudioTapErrorDomain] &&
                error.code == kAudioTapNonFatalProcessListRefreshErrorCode) {
              return;
            }
            Fail(error, /*fromVideo=*/false);
          },
          [] {});
      audioTap_->Start();

      // audioTap_->Start() can invoke HandleAudioPCM (on the tap's own queue) before this function
      // returns — audioEncoder_ is written here under audioEncoderMutex_, and HandleAudioPCM reads
      // it under the same lock, so that racing read can never observe a partially-constructed
      // pointer; it just sees "not ready yet" and skips the buffer (see av_recording.mm's
      // identical note for the full reasoning).
      auto encoder = std::make_unique<AudioEncoder>(
          audioTap_->Format(), [this](CMSampleBufferRef sampleBuffer) { HandleAudioSample(sampleBuffer); },
          &clockOrigin_);
      {
        std::lock_guard<std::mutex> lock(audioEncoderMutex_);
        audioEncoder_ = std::move(encoder);
      }

      videoEncoder_ = std::make_unique<VideoFrameEncoder>(
          device_, videoOptions_, [this](CMSampleBufferRef sampleBuffer) { HandleVideoSample(sampleBuffer); },
          [this](NSError* error) { Fail(error, /*fromVideo=*/true); }, [] {}, &clockOrigin_);
      videoEncoder_->Start();
    } catch (...) {
      running_ = false;
      StopInternal();
      throw;
    }
  }

  void Stop() { StopInternal(); }

  void RequestKeyFrame() {
    if (videoEncoder_) {
      videoEncoder_->RequestKeyFrame();
    }
  }

 private:
  // Runs on AudioTapSession's own serial queue — audioEncoder_ is only ever read/written under
  // audioEncoderMutex_ (see Start()'s comment). If EncodePCM throws, it's intentionally left to
  // propagate out of here: AudioTapSession::HandleBuffer (this callback's own caller) catches it,
  // reports it via the onError callback (-> Fail()), and safely stops itself — see
  // sim_audio_tap.h's onBuffer doc comment for why this method must never try to stop audioTap_
  // itself (it's running on audioTap_'s own queue — would deadlock).
  void HandleAudioPCM(const AudioBufferList* data, const AudioTimeStamp* time) {
    AudioEncoder* encoder;
    {
      std::lock_guard<std::mutex> lock(audioEncoderMutex_);
      if (!running_) {
        return;
      }
      encoder = audioEncoder_.get();
    }
    if (encoder != nullptr) {
      encoder->EncodePCM(data, time);
    }
  }

  void HandleVideoSample(CMSampleBufferRef sampleBuffer) {
    if (!running_) {
      return;
    }
    bool isKeyFrame = IsKeyFrame(sampleBuffer);
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    AVAccessUnit unit;
    unit.track = AVTrack::kVideo;
    unit.isKeyFrame = isKeyFrame;
    unit.sequence = videoSequence_++;
    unit.timestampMicros = pts.timescale != 0 ? (pts.value * 1000000 / pts.timescale) : 0;
    RepackAsAnnexB(unit.data, sampleBuffer, isKeyFrame, videoOptions_.codec);
    if (onAccessUnit_) {
      onAccessUnit_(std::move(unit));
    }
  }

  void HandleAudioSample(CMSampleBufferRef sampleBuffer) {
    if (!running_) {
      return;
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (block == nullptr) {
      return;
    }
    size_t length = CMBlockBufferGetDataLength(block);
    AVAccessUnit unit;
    unit.track = AVTrack::kAudio;
    unit.isKeyFrame = true;  // every AAC-LC packet is independently decodable
    unit.sequence = audioSequence_++;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    unit.timestampMicros = pts.timescale != 0 ? (pts.value * 1000000 / pts.timescale) : 0;
    unit.data.resize(length);
    if (CMBlockBufferCopyDataBytes(block, 0, length, unit.data.data()) != kCMBlockBufferNoErr) {
      return;
    }
    if (onAccessUnit_) {
      onAccessUnit_(std::move(unit));
    }
  }

  // Called from either encoder's onError. Stops only the OTHER (still-running) encoder
  // synchronously — the failing one is already tearing itself down internally right after this
  // callback returns (its own error path); calling its own blocking Stop() from within its own
  // callback would deadlock. Its actual resource teardown still completes on its own schedule —
  // safe, since it guarantees no further onSample_ call once its own error path started (see
  // av_recording.mm's identical note for the full reasoning).
  void Fail(NSError* error, bool fromVideo) {
    if (!running_.exchange(false)) {
      return;  // already stopping/stopped
    }
    if (fromVideo) {
      if (audioTap_) {
        audioTap_->Stop();
      }
    } else {
      if (videoEncoder_) {
        videoEncoder_->Stop();
      }
    }
    if (onError_) {
      onError_(error);
    }
    if (onEnd_) {
      onEnd_();
    }
  }

  void StopInternal() {
    if (!running_.exchange(false)) {
      return;  // idempotent
    }
    if (videoEncoder_) {
      videoEncoder_->Stop();
    }
    if (audioTap_) {
      audioTap_->Stop();
    }
    if (onEnd_) {
      onEnd_();
    }
  }

  id device_;
  NSString* udid_;
  VideoEncoderOptions videoOptions_;
  std::function<void(AVAccessUnit)> onAccessUnit_;
  std::function<void(NSError*)> onError_;
  std::function<void()> onEnd_;

  double clockOrigin_ = 0;
  std::unique_ptr<VideoFrameEncoder> videoEncoder_;
  std::unique_ptr<AudioTapSession> audioTap_;
  std::mutex audioEncoderMutex_;  // guards audioEncoder_ — see HandleAudioPCM/Start()
  std::unique_ptr<AudioEncoder> audioEncoder_;

  std::atomic<uint64_t> videoSequence_{0};
  std::atomic<uint64_t> audioSequence_{0};
  std::atomic<bool> running_{false};
};

AVStreamSession::AVStreamSession(id device, NSString* udid, VideoEncoderOptions videoOptions,
                                 std::function<void(AVAccessUnit)> onAccessUnit, std::function<void(NSError*)> onError,
                                 std::function<void()> onEnd)
    : impl_(std::make_unique<Impl>(device, udid, videoOptions, std::move(onAccessUnit), std::move(onError),
                                   std::move(onEnd))) {}

AVStreamSession::~AVStreamSession() = default;

void AVStreamSession::Start() { impl_->Start(); }

void AVStreamSession::Stop() { impl_->Stop(); }

void AVStreamSession::RequestKeyFrame() { impl_->RequestKeyFrame(); }

}  // namespace coresim
