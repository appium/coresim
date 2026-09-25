#include "video_encoder.h"

#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <atomic>

#include "monotonic_clock.h"
#include "nserror_bridge.h"
#include "safe_dispatch.h"
#include "sim_screenshot.h"

namespace coresim {

namespace {

NSString* const kVideoEncoderErrorDomain = @"io.appium.coresim.VideoEncoder";

NSError* MakeError(NSInteger code, NSString* message) {
  return [NSError errorWithDomain:kVideoEncoderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

NSError* MakeStatusError(NSInteger code, NSString* what, OSStatus status) {
  return MakeError(code, [NSString stringWithFormat:@"%@ (OSStatus %d)", what, static_cast<int>(status)]);
}

void AppendAnnexB(std::vector<uint8_t>& out, const uint8_t* nal, size_t length) {
  static const uint8_t kStartCode[4] = {0, 0, 0, 1};
  out.insert(out.end(), kStartCode, kStartCode + 4);
  out.insert(out.end(), nal, nal + length);
}

// CMBlockBufferGetDataPointer's pointer only covers the contiguous region starting at the given
// offset, which for a segmented buffer (multiple backing memory blocks — CoreMedia's documented
// contract, not just a VideoToolbox implementation detail) can be far shorter than totalLength;
// reading up to totalLength through it would run past that region. CopyDataBytes stitches
// segments together into a caller-owned, guaranteed-contiguous copy instead.
void AppendSampleBufferNALs(std::vector<uint8_t>& out, CMSampleBufferRef sampleBuffer) {
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
  if (block == nullptr) {
    return;
  }
  size_t totalLength = CMBlockBufferGetDataLength(block);
  if (totalLength == 0) {
    return;
  }
  std::vector<uint8_t> data(totalLength);
  if (CMBlockBufferCopyDataBytes(block, 0, totalLength, data.data()) != kCMBlockBufferNoErr) {
    return;
  }
  const uint8_t* dataPointer = data.data();
  size_t offset = 0;
  while (offset + 4 <= totalLength) {
    uint32_t nalLength = (static_cast<uint32_t>(dataPointer[offset]) << 24) |
                         (static_cast<uint32_t>(dataPointer[offset + 1]) << 16) |
                         (static_cast<uint32_t>(dataPointer[offset + 2]) << 8) | dataPointer[offset + 3];
    offset += 4;
    if (nalLength == 0 || offset + nalLength > totalLength) {
      break;
    }
    AppendAnnexB(out, dataPointer + offset, nalLength);
    offset += nalLength;
  }
}

using ParameterSetAtIndexFn = OSStatus (*)(CMFormatDescriptionRef, size_t, const uint8_t**, size_t*, size_t*, int*);

void AppendParameterSets(std::vector<uint8_t>& out, CMFormatDescriptionRef format, ParameterSetAtIndexFn getAtIndex) {
  size_t count = 0;
  if (getAtIndex(format, 0, nullptr, nullptr, &count, nullptr) != noErr) {
    return;
  }
  for (size_t i = 0; i < count; i++) {
    const uint8_t* bytes = nullptr;
    size_t size = 0;
    if (getAtIndex(format, i, &bytes, &size, nullptr, nullptr) == noErr) {
      AppendAnnexB(out, bytes, size);
    }
  }
}

}  // namespace

bool IsKeyFrame(CMSampleBufferRef sampleBuffer) {
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    return true;
  }
  CFDictionaryRef attachment = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
  return !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
}

void RepackAsAnnexB(std::vector<uint8_t>& out, CMSampleBufferRef sampleBuffer, bool isKeyFrame,
                    VideoStreamCodec codec) {
  if (isKeyFrame) {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (format != nullptr) {
      if (codec == VideoStreamCodec::kHEVC) {
        AppendParameterSets(out, format, CMVideoFormatDescriptionGetHEVCParameterSetAtIndex);
      } else {
        AppendParameterSets(out, format, CMVideoFormatDescriptionGetH264ParameterSetAtIndex);
      }
    }
  }
  AppendSampleBufferNALs(out, sampleBuffer);
}

class VideoFrameEncoder::Impl {
 public:
  Impl(id device, VideoEncoderOptions options, std::function<void(CMSampleBufferRef)> onSample,
       std::function<void(NSError*)> onError, std::function<void()> onEnd, const double* sharedClockOrigin)
      : device_(device),
        options_(options),
        onSample_(std::move(onSample)),
        onError_(std::move(onError)),
        onEnd_(std::move(onEnd)),
        sharedClockOrigin_(sharedClockOrigin) {
    queue_ = dispatch_queue_create("io.appium.coresim.videoEncoder", DISPATCH_QUEUE_SERIAL);
  }

  ~Impl() { Stop(); }

  void Start() {
    NSError* error = nil;
    id descriptor = ResolveCaptureDisplay(device_, options_.displayId, &error);
    if (descriptor == nil) {
      throw NSErrorException(error);
    }
    id surfaceObj = CurrentDisplaySurface(descriptor);
    if (surfaceObj == nil) {
      throw NSErrorException(MakeError(4, @"The device's display surface is not available yet"));
    }
    IOSurfaceRef surface = (__bridge IOSurfaceRef)surfaceObj;
    // Set up synchronously (not lazily on the first Tick()) so a setup failure rejects Start()
    // directly rather than only reaching onError, which the caller may not be listening for yet.
    NSError* setupError = nil;
    if (!SetUpSession(surface, &setupError)) {
      throw NSErrorException(setupError);
    }
    // Must be set before EncodeSurface below — both it and HandleEncodedSample measure elapsed
    // time from this. A caller-supplied origin (see the constructor) is used as-is, not offset
    // further — the gap between it being captured and this line running is itself the correct,
    // meaningful startup latency to bake into this encoder's PTS zero, for sync with a peer
    // AudioEncoder given the same origin (av_recording.h/av_stream.h).
    startTime_ = sharedClockOrigin_ != nullptr ? *sharedClockOrigin_ : MonotonicSeconds();
    // Encode immediately rather than waiting for a *changed* seed on the first tick, or the
    // stream would stay silent until the display changes again. running_ is set true before this
    // call (not after), since VTCompressionSessionEncodeFrame's output callback can in principle
    // fire on another thread before this one returns — HandleEncodedSample discards samples while
    // running_ is false, which would otherwise silently drop the stream's very first (keyframe)
    // sample. A failure resets it and tears session_ down itself here, rather than going through
    // Stop()/onEnd_ (see coresim.mm — onEnd_ firing this early would double-release its
    // ThreadSafeFunctions).
    running_ = true;
    bool encoded = false;
    try {
      encoded = EncodeSurface(surface);
    } catch (...) {
      running_ = false;
      VTCompressionSessionInvalidate(session_);
      CFRelease(session_);
      session_ = nullptr;
      throw;
    }
    // Only commit the seed once a frame was actually submitted — a transient pixel-buffer
    // creation failure (EncodeSurface returning false) otherwise leaves lastSeed_ at its default
    // 0, so the first Tick() sees the real seed as "changed" and retries automatically instead of
    // the stream going silent forever on a display that never changes again.
    if (encoded) {
      lastSeed_ = IOSurfaceGetSeed(surface);
    }

    double interval = 1.0 / std::max(options_.fps, 1.0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue_);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              static_cast<uint64_t>(interval * NSEC_PER_SEC),
                              static_cast<uint64_t>(interval * NSEC_PER_SEC / 10));
    // `this` outlives the timer: Stop()/StopFromQueue() always drain or outrun it before `this`
    // can be destroyed (see their comments below).
    dispatch_source_set_event_handler(timer, ^{
      Tick();
    });
    timer_ = timer;
    dispatch_resume(timer_);
  }

  // Callable from any thread except `queue_` itself (would deadlock on the dispatch_sync below).
  void Stop() {
    if (!running_.exchange(false)) {
      return;  // idempotent
    }
    if (timer_ != nullptr) {
      dispatch_source_cancel(timer_);
      // Blocks until any in-flight Tick() finishes — by then running_ is already false, so it
      // won't touch session_ again.
      dispatch_sync(queue_, ^{
                    });
      timer_ = nullptr;
    }
    TearDownSessionAndFireEnd();
  }

  void RequestKeyFrame() { forceKeyFrame_ = true; }

 private:
  // Same as Stop() minus the dispatch_sync barrier — only safe from within Tick() itself, already
  // serialized on `queue_`; would race a concurrent Tick() from any other thread.
  void StopFromQueue() {
    if (!running_.exchange(false)) {
      return;  // idempotent — e.g. an external Stop() already won this race
    }
    if (timer_ != nullptr) {
      dispatch_source_cancel(timer_);
      timer_ = nullptr;
    }
    TearDownSessionAndFireEnd();
  }

  void TearDownSessionAndFireEnd() {
    if (session_ != nullptr) {
      // Flushes and blocks until every already-submitted frame's callback has returned — without
      // this, a frame submitted just before Stop() could fire after onEnd_ releases whatever
      // resources the caller tied to it (e.g. ThreadSafeFunctions — see CLAUDE.md).
      VTCompressionSessionCompleteFrames(session_, kCMTimeInvalid);
      VTCompressionSessionInvalidate(session_);
      CFRelease(session_);
      session_ = nullptr;
    }
    if (onEnd_) {
      onEnd_();
    }
  }

  void Tick() {
    if (!running_) {
      return;
    }
    if (pendingErrorTeardown_) {
      // HandleEncodedSample (below) can run on VideoToolbox's own callback thread, where it's
      // unsafe to tear down directly — StopFromQueue()/CompleteFrames() are only safe already
      // serialized on `queue_` (here), and CompleteFrames specifically would deadlock waiting on
      // its own still-executing callback. It sets this flag instead; picked up on the very next
      // tick (queue_-serialized, safe) rather than via a raw cross-thread dispatch, since nothing
      // here can outlive `this` the way a block captured on another thread otherwise could.
      StopFromQueue();
      return;
    }
    @autoreleasepool {
      try {
        // Re-resolved every tick (like CaptureScreenshot does), not cached once in Start(), so a
        // deleted device or disconnected display surfaces a real error instead of Tick() quietly
        // doing nothing forever.
        NSError* resolveError = nil;
        id descriptor = ResolveCaptureDisplay(device_, options_.displayId, &resolveError);
        if (descriptor == nil) {
          if (onError_) {
            onError_(resolveError);
          }
          StopFromQueue();
          return;
        }
        id surfaceObj = CurrentDisplaySurface(descriptor);
        if (surfaceObj == nil) {
          return;  // transient — the connection may not have a frame ready yet, try again next tick
        }
        IOSurfaceRef surface = (__bridge IOSurfaceRef)surfaceObj;
        uint32_t seed = IOSurfaceGetSeed(surface);
        if (seed == lastSeed_) {
          return;  // unchanged since the last tick — mirrors CoreSimulator's own recorder, which
                   // only encodes a frame when the display actually changes (see CLAUDE.md)
        }
        // Only commit the new seed once EncodeSurface actually submits it — a transient failure
        // (pixel-buffer creation) must leave lastSeed_ stale so the next tick retries this same
        // frame instead of silently going quiet until the display changes again.
        if (EncodeSurface(surface)) {
          lastSeed_ = seed;
        }
      } catch (const std::exception& e) {
        // Without this, an exception here (e.g. a dropped display-proxy connection) would escape
        // this bare GCD timer handler uncaught and crash the whole process (see CLAUDE.md).
        if (onError_) {
          onError_(MakeError(3, [NSString stringWithFormat:@"Video encoding failed: %s", e.what()]));
        }
        StopFromQueue();
      }
    }
  }

  bool SetUpSession(IOSurfaceRef surface, NSError** error) {
    int32_t width = static_cast<int32_t>(IOSurfaceGetWidth(surface));
    int32_t height = static_cast<int32_t>(IOSurfaceGetHeight(surface));
    CMVideoCodecType codecType =
        options_.codec == VideoStreamCodec::kHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, width, height, codecType, nullptr, nullptr,
                                                 kCFAllocatorDefault, OutputCallback, this, &session_);
    if (status != noErr) {
      *error = MakeStatusError(1, @"Failed to create a VTCompressionSession", status);
      return false;
    }
    // Clamped like Start()'s timer interval — an unvalidated 0 here would set MaxKeyFrameInterval
    // to an out-of-spec value.
    double fps = std::max(options_.fps, 1.0);
    status = VTSessionSetProperty(session_, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    if (status == noErr) {
      status = VTSessionSetProperty(session_, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    }
    if (status == noErr) {
      status = VTSessionSetProperty(session_, kVTCompressionPropertyKey_AverageBitRate,
                                    (__bridge CFNumberRef) @(options_.bitrate));
    }
    if (status == noErr) {
      status =
          VTSessionSetProperty(session_, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef) @(fps));
    }
    if (status == noErr) {
      status = VTSessionSetProperty(session_, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                    (__bridge CFNumberRef) @(static_cast<int>(fps * 2)));
    }
    if (status != noErr) {
      *error = MakeStatusError(2, @"Failed to configure the VTCompressionSession", status);
      VTCompressionSessionInvalidate(session_);
      CFRelease(session_);
      session_ = nullptr;
      return false;
    }
    VTCompressionSessionPrepareToEncodeFrames(session_);
    return true;
  }

  // Returns whether a frame was actually submitted to the encoder — false for a transient
  // pixel-buffer creation failure the caller should retry, as opposed to a real encode failure
  // (thrown, not returned, since that tears down the whole session).
  bool EncodeSurface(IOSurfaceRef surface) {
    CVPixelBufferRef pixelBuffer = nullptr;
    CVReturn cvStatus = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nullptr, &pixelBuffer);
    if (cvStatus != kCVReturnSuccess || pixelBuffer == nullptr) {
      return false;  // transient — try again next tick rather than tearing down the whole session
    }
    CMTime pts = CMTimeMake(static_cast<int64_t>((MonotonicSeconds() - startTime_) * 1000000), 1000000);
    NSDictionary* frameProperties = nil;
    if (forceKeyFrame_.exchange(false)) {
      frameProperties = @{(__bridge NSString*)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES};
    }
    OSStatus status = VTCompressionSessionEncodeFrame(session_, pixelBuffer, pts, kCMTimeInvalid,
                                                      (__bridge CFDictionaryRef)frameProperties, nullptr, nullptr);
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr) {
      throw std::runtime_error([[NSString stringWithFormat:@"VTCompressionSessionEncodeFrame failed (OSStatus %d)",
                                                           static_cast<int>(status)] UTF8String]);
    }
    return true;
  }

  static void OutputCallback(void* outputCallbackRefCon, void* /*sourceFrameRefCon*/, OSStatus status,
                             VTEncodeInfoFlags /*infoFlags*/, CMSampleBufferRef sampleBuffer) {
    static_cast<Impl*>(outputCallbackRefCon)->HandleEncodedSample(status, sampleBuffer);
  }

  void HandleEncodedSample(OSStatus status, CMSampleBufferRef sampleBuffer) {
    if (!running_) {
      return;
    }
    if (status != noErr) {
      // Only the first failure is reported — pendingErrorTeardown_ doubles as the report-once
      // gate, since Tick() (the only place that consumes it) only ever needs to see it once too.
      if (!pendingErrorTeardown_.exchange(true)) {
        if (onError_) {
          onError_(MakeStatusError(3, @"VideoToolbox reported an encoding failure", status));
        }
      }
      return;
    }
    if (sampleBuffer == nullptr) {
      return;
    }
    if (onSample_) {
      onSample_(sampleBuffer);
    }
  }

  id device_;
  VideoEncoderOptions options_;
  std::function<void(CMSampleBufferRef)> onSample_;
  std::function<void(NSError*)> onError_;
  std::function<void()> onEnd_;
  const double* sharedClockOrigin_;

  dispatch_queue_t queue_ = nullptr;
  dispatch_source_t timer_ = nullptr;
  VTCompressionSessionRef session_ = nullptr;
  uint32_t lastSeed_ = 0;
  double startTime_ = 0;
  std::atomic<bool> running_{false};
  // Set by HandleEncodedSample (possibly off queue_) on an encoder failure, consumed by the next
  // Tick() (on queue_) — see both for why teardown can't just happen inline there.
  std::atomic<bool> pendingErrorTeardown_{false};
  std::atomic<bool> forceKeyFrame_{false};
};

VideoFrameEncoder::VideoFrameEncoder(id device, VideoEncoderOptions options,
                                     std::function<void(CMSampleBufferRef)> onSample,
                                     std::function<void(NSError*)> onError, std::function<void()> onEnd,
                                     const double* sharedClockOrigin)
    : impl_(std::make_unique<Impl>(device, options, std::move(onSample), std::move(onError), std::move(onEnd),
                                   sharedClockOrigin)) {}

VideoFrameEncoder::~VideoFrameEncoder() = default;

void VideoFrameEncoder::Start() { impl_->Start(); }

void VideoFrameEncoder::Stop() { impl_->Stop(); }

void VideoFrameEncoder::RequestKeyFrame() { impl_->RequestKeyFrame(); }

}  // namespace coresim
