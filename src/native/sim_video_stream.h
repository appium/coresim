#pragma once

#import <Foundation/Foundation.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

namespace coresim {

enum class VideoStreamCodec { kH264, kHEVC };

// One encoded frame — Annex-B start-code-prefixed NAL units, concatenated. A keyframe's `data`
// has the stream's parameter sets (SPS/PPS, or VPS/SPS/PPS for HEVC) prepended, making every
// keyframe self-decodable on its own — the standard convention for a raw Annex-B elementary
// stream (e.g. what ffmpeg's `-f h264`/`-f hevc` demuxers expect).
struct VideoAccessUnit {
  std::vector<uint8_t> data;
  bool isKeyFrame = false;
  uint64_t sequence = 0;
  // Microseconds since the stream started.
  int64_t timestampMicros = 0;
};

struct VideoStreamOptions {
  VideoStreamCodec codec = VideoStreamCodec::kH264;
  NSString* displayId = nil;
  double fps = 15.0;
  int bitrate = 2000000;
};

// Polls the same live display `IOSurface` CaptureScreenshot/StartVideoRecording read/resolve (see
// sim_screenshot.h) on a dedicated serial queue, encoding each changed frame in real time via the
// public VideoToolbox API. Unlike StartVideoRecording (sim_video_recording.h), which drives
// CoreSimulator's own private, file-only recorder, this delivers access units live as they're
// encoded — no private API, no file.
//
// Thread-safety: the constructor/Start()/Stop() may be called from any thread; `onAccessUnit`/
// `onError` are invoked on the session's own internal serial queue, never concurrently with each
// other, and never after `onEnd` has fired. `onEnd` fires exactly once — from an explicit Stop()
// call, or on its own if the polling loop fails internally (e.g. VTCompressionSession setup) —
// and is the caller's one reliable signal that it's safe to release any resources (e.g. N-API
// ThreadSafeFunctions) `onAccessUnit`/`onError` themselves hold, since neither of those has a
// "this was the last call" signal of its own.
class VideoStreamSession {
 public:
  VideoStreamSession(id device, VideoStreamOptions options, std::function<void(VideoAccessUnit)> onAccessUnit,
                      std::function<void(NSError*)> onError, std::function<void()> onEnd);
  ~VideoStreamSession();

  VideoStreamSession(const VideoStreamSession&) = delete;
  VideoStreamSession& operator=(const VideoStreamSession&) = delete;

  // Resolves the display and starts the encoder's polling loop. Throws NSErrorException/
  // ObjCException/NativeSimUnavailableError synchronously for the same resolution failures
  // StartVideoRecording can hit (see sim_screenshot.h's ResolveCaptureDisplay) — `onEnd` is never
  // called in that case, since the stream never actually started. Failures that happen later,
  // asynchronously, on the polling loop itself (e.g. VTCompressionSession setup, which needs an
  // actual frame to size itself) are reported to `onError` instead, immediately followed by
  // `onEnd` — never thrown.
  void Start();

  // Idempotent; blocks until the polling loop has fully stopped and the compression session is
  // torn down — no further onAccessUnit/onError call is in flight or will happen once this
  // returns, and `onEnd` has already fired by the time it does (unless the loop already stopped
  // itself first, in which case this just observes that). Safe to call from ~VideoStreamSession
  // (also idempotent via the same guard) — but never from inside `onAccessUnit`/`onError`/`onEnd`
  // themselves, which run on the same queue this blocks on (that would deadlock).
  void Stop();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace coresim
