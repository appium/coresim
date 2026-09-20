#pragma once

#import <Foundation/Foundation.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

namespace coresim {

enum class VideoStreamCodec { kH264, kHEVC };

// One encoded frame — Annex-B NAL units, concatenated. A keyframe's `data` has parameter sets
// (SPS/PPS, or VPS/SPS/PPS for HEVC) prepended, so every keyframe is self-decodable alone.
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

// Polls the live display IOSurface (sim_screenshot.h) on a serial queue and encodes changed
// frames via the public VideoToolbox API — unlike StartVideoRecording's private, file-only
// recorder, this delivers access units live. Full thread-safety contract: see CLAUDE.md.
class VideoStreamSession {
 public:
  VideoStreamSession(id device, VideoStreamOptions options, std::function<void(VideoAccessUnit)> onAccessUnit,
                      std::function<void(NSError*)> onError, std::function<void()> onEnd);
  ~VideoStreamSession();

  VideoStreamSession(const VideoStreamSession&) = delete;
  VideoStreamSession& operator=(const VideoStreamSession&) = delete;

  // Resolves the display and starts the polling loop; throws synchronously on resolution/setup
  // failure (`onEnd` never called then). Later failures go to `onError`, then `onEnd`.
  void Start();

  // Idempotent; blocks until the loop has fully stopped. Never call from inside onAccessUnit/
  // onError/onEnd — same queue this blocks on, so it would deadlock.
  void Stop();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace coresim
