#pragma once

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <functional>
#include <memory>

#include "video_encoder.h"

namespace coresim {

// File recording via this addon's own encoders — independent of StartVideoRecording's private
// CoreSimulator recorder (sim_video_recording.h), which has no per-frame hook to mux audio into
// and no `fps` knob. Drives a VideoFrameEncoder (video_encoder.h) and, when `captureAudio` is set,
// an AudioTapSession+AudioEncoder (sim_audio_tap.h/audio_encoder.h) too, both on one shared PTS
// clock (monotonic_clock.h), muxing the encoder(s)' already-encoded output into one file via
// AVAssetWriter passthrough — neither track is re-encoded by the writer itself. Without
// `captureAudio`, this is a video-only recording (same VideoFrameEncoder `startVideoStream` uses)
// reached when `fps` is requested without `audio` — see coresim.mm's StartVideoRecording.
//
// IMPORTANT: with `captureAudio`, needs the host's "System Audio Recording Only" TCC permission —
// see sim_audio_tap.h.
class AVRecordingSession {
 public:
  AVRecordingSession(id device, NSString* udid, VideoEncoderOptions videoOptions, NSString* outputFile,
                     bool captureAudio);
  ~AVRecordingSession();

  AVRecordingSession(const AVRecordingSession&) = delete;
  AVRecordingSession& operator=(const AVRecordingSession&) = delete;

  // Resolves the display and starts the video encoder (plus the audio tap + encoder, if
  // `captureAudio` was set); throws synchronously on setup failure (none of the callbacks ever
  // called then). `onFirstSample` fires once, after the AVAssetWriter session has actually started
  // — needs a first video sample, to learn its format (and, with `captureAudio`, the audio format
  // too, known immediately once the tap resolves) — mirrors StartVideoRecording's "resolves once
  // the first frame is recorded" contract. `onError` covers
  // a later failure from either encoder or the writer, firing at most once; the session tears
  // itself down before calling it, so a following Stop() is always safe (and required, to reclaim
  // the writer/file). `onEnd` fires exactly once, always — right after `onError` if it fired, or
  // once Stop() has fully finished otherwise — the single safe point to release any resources
  // (e.g. ThreadSafeFunctions) tied to this session's lifetime, mirroring VideoStreamSession.
  void Start(std::function<void()> onFirstSample, std::function<void(NSError*)> onError, std::function<void()> onEnd);

  // Finalizes the output file. `onFinished` fires once (non-nil NSError* on failure, including
  // when `onError` already fired earlier — in that case this just reports the same failure rather
  // than attempting to finalize an already-cancelled writer). Safe to call even if no frame was
  // ever captured (reports an error instead of producing an empty file).
  void Stop(std::function<void(NSError*)> onFinished);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace coresim
