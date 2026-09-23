#include "sim_jpeg_stream.h"

#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>

#include <algorithm>
#include <atomic>

#include "monotonic_clock.h"
#include "nserror_bridge.h"
#include "sim_screenshot.h"

namespace coresim {

namespace {

NSString* const kJpegStreamErrorDomain = @"io.appium.coresim.JpegStream";

NSError* MakeError(NSInteger code, NSString* message) {
  return [NSError errorWithDomain:kJpegStreamErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

}  // namespace

class JpegStreamSession::Impl {
 public:
  Impl(id device, JpegStreamOptions options, std::function<void(JpegFrame)> onFrame,
       std::function<void(NSError*)> onError, std::function<void()> onEnd, std::function<void()> onAbortDelivery)
      : device_(device),
        options_(options),
        onFrame_(std::move(onFrame)),
        onError_(std::move(onError)),
        onEnd_(std::move(onEnd)),
        onAbortDelivery_(std::move(onAbortDelivery)) {
    queue_ = dispatch_queue_create("io.appium.coresim.jpegStream", DISPATCH_QUEUE_SERIAL);
    // Persistent, unlike CaptureScreenshot's own one-shot CIContext (see sim_screenshot.mm) — that
    // file's comment calls this out as exactly the tradeoff a continuous streaming path should
    // make instead.
    context_ = [CIContext contextWithOptions:nil];
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
      throw NSErrorException(MakeError(1, @"The device's display surface is not available yet"));
    }
    IOSurfaceRef surface = (__bridge IOSurfaceRef)surfaceObj;

    startTime_ = MonotonicSeconds();
    // Set before the initial encode below — EmitFrame measures elapsed time from it, and running_
    // gates whether a frame is delivered at all (see Tick()'s own check).
    running_ = true;
    NSData* data = nil;
    NSError* encodeError = nil;
    bool encoded = EncodeSurface(surface, &data, &encodeError);
    if (encodeError != nil) {
      running_ = false;
      throw NSErrorException(encodeError);
    }
    // Encode immediately rather than waiting for a *changed* seed on the first tick, or the stream
    // would stay silent until the display changes again. Only commit the seed once a frame was
    // actually produced — a transient failure (nil CIImage/CGImage) otherwise leaves lastSeed_ at
    // its default 0, so the first Tick() sees the real seed as "changed" and retries automatically.
    if (encoded) {
      lastSeed_ = IOSurfaceGetSeed(surface);
      EmitFrame(data);
    }

    double interval = 1.0 / std::max(options_.fps, 1.0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue_);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              static_cast<uint64_t>(interval * NSEC_PER_SEC),
                              static_cast<uint64_t>(interval * NSEC_PER_SEC / 10));
    // `this` outlives the timer: Stop()/StopFromQueue() always cancel or outrun it before `this`
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
      // won't emit another frame.
      dispatch_sync(queue_, ^{
                    });
      timer_ = nullptr;
    }
    if (onEnd_) {
      onEnd_();
    }
  }

  void AbortDelivery() {
    if (onAbortDelivery_) {
      onAbortDelivery_();
    }
  }

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
    if (onEnd_) {
      onEnd_();
    }
  }

  void Tick() {
    if (!running_) {
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
          return;  // unchanged since the last tick — mirrors VideoFrameEncoder's own seed check
        }
        NSData* data = nil;
        NSError* encodeError = nil;
        // Only commit the new seed once EncodeSurface actually produced a frame — a transient
        // failure must leave lastSeed_ stale so the next tick retries this same frame instead of
        // silently going quiet until the display changes again.
        bool encoded = EncodeSurface(surface, &data, &encodeError);
        if (encodeError != nil) {
          if (onError_) {
            onError_(encodeError);
          }
          StopFromQueue();
          return;
        }
        if (encoded) {
          lastSeed_ = seed;
          EmitFrame(data);
        }
      } catch (const std::exception& e) {
        // Without this, an exception here (e.g. a dropped display-proxy connection, which surfaces
        // as NativeSimUnavailableError/ObjCException — both std::exception subtypes — via
        // ResolveCaptureDisplay's own dynamic dispatch) would escape this bare GCD timer handler
        // uncaught and crash the whole process (see CLAUDE.md; mirrors VideoFrameEncoder::Tick()).
        if (onError_) {
          onError_(MakeError(4, [NSString stringWithFormat:@"JPEG streaming failed: %s", e.what()]));
        }
        StopFromQueue();
      }
    }
  }

  // Returns whether a frame was produced. Sets *error only for a genuine encode failure that
  // should end the whole session; a false return with *error left nil means "transient, retry
  // next tick" (mirrors VideoFrameEncoder::EncodeSurface's identical CVPixelBufferCreateWithIOSurface
  // transient-failure contract in video_encoder.mm).
  bool EncodeSurface(IOSurfaceRef surface, NSData** outData, NSError** error) {
    CIImage* ciImage = [CIImage imageWithIOSurface:surface];
    if (ciImage == nil) {
      return false;
    }
    // Scaling the CIImage before rendering (rather than resizing the already-encoded JPEG
    // afterward, the way e.g. WebDriverAgent's own scaling does) means the CGImage/JPEG below is
    // produced at the target resolution directly — no extra decode/resize/re-encode round trip.
    if (options_.scale != 1.0) {
      ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(options_.scale, options_.scale)];
    }
    CGImageRef cgImage = [context_ createCGImage:ciImage fromRect:ciImage.extent];
    if (cgImage == nil) {
      return false;
    }
    // Same CGImageDestination-based encode CaptureScreenshot's kJPEG format uses (sim_screenshot.mm).
    NSData* imageData = EncodeImage(cgImage, ScreenshotFormat::kJPEG, options_.jpegQualityPercent, error);
    CGImageRelease(cgImage);
    if (imageData == nil) {
      return false;
    }
    *outData = imageData;
    return true;
  }

  // Only ever called from `queue_` (Start()'s initial encode, or Tick()) — never concurrently, so
  // sequence_ needs no synchronization, unlike VideoStreamSession's (whose encoder callback can
  // run on a different thread).
  void EmitFrame(NSData* data) {
    JpegFrame frame;
    frame.sequence = sequence_++;
    frame.timestampMicros = static_cast<int64_t>((MonotonicSeconds() - startTime_) * 1000000);
    const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
    frame.data.assign(bytes, bytes + data.length);
    if (onFrame_) {
      onFrame_(std::move(frame));
    }
  }

  id device_;
  JpegStreamOptions options_;
  std::function<void(JpegFrame)> onFrame_;
  std::function<void(NSError*)> onError_;
  std::function<void()> onEnd_;
  std::function<void()> onAbortDelivery_;

  dispatch_queue_t queue_ = nullptr;
  dispatch_source_t timer_ = nullptr;
  CIContext* context_ = nil;
  uint32_t lastSeed_ = 0;
  double startTime_ = 0;
  uint64_t sequence_ = 0;
  std::atomic<bool> running_{false};
};

JpegStreamSession::JpegStreamSession(id device, JpegStreamOptions options, std::function<void(JpegFrame)> onFrame,
                                     std::function<void(NSError*)> onError, std::function<void()> onEnd,
                                     std::function<void()> onAbortDelivery)
    : impl_(std::make_unique<Impl>(device, options, std::move(onFrame), std::move(onError), std::move(onEnd),
                                   std::move(onAbortDelivery))) {}

JpegStreamSession::~JpegStreamSession() = default;

void JpegStreamSession::Start() { impl_->Start(); }

void JpegStreamSession::Stop() { impl_->Stop(); }

void JpegStreamSession::AbortDelivery() { impl_->AbortDelivery(); }

}  // namespace coresim
