#pragma once

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

namespace coresim {

// `maskPolicy` for a non-rectangular display (e.g. a Dynamic Island cutout). Raw int values
// confirmed empirically against real recordings (compared frame-by-frame with `ffprobe` against
// real `xcrun simctl io recordVideo` output) — `kAlpha` is accepted but not actually
// distinguishable from `kBlack` in the captured pixels, matching `simctl`'s own `--mask` help text
// ("alpha: Not supported ... the mask is rendered black").
enum class VideoMaskPolicy : long long {
  kIgnored = 0,
  kAlpha = 1,
  kBlack = 2,
};

// Starts recording `displayId` (nil = primary display, same resolution/fallback rules as
// CaptureScreenshot — see sim_screenshot.h) to `outputFile`, an absolute filesystem path — NOT a
// `file://` URL, confirmed empirically to hang `handler` forever instead of erroring (see
// CLAUDE.md). `assetWriterOutputSettings` is passed through verbatim to the underlying
// AVAssetWriter (e.g. `@{AVVideoCodecKey: AVVideoCodecTypeHEVC}`); an empty dictionary records
// H.264 — CoreSimulator's own default here, distinct from `simctl io recordVideo`'s CLI-level
// default of HEVC, which is simply `simctl` always passing the key explicitly.
//
// Returns NO (and sets *error) for the same synchronous resolution failures CaptureScreenshot can
// hit (no IO client, no matching/renderable display, or this CoreSimulator version has no video
// capture service at all) — `handler` is never called in that case. On success, `handler` fires
// once the first frame has actually been recorded (mirrors `simctl`'s own "Recording started"
// signal, printed once CoreSimulator has processed the first frame) with a non-nil NSError on
// failure — never before then, so code that awaits this resolving is always safe to call
// StopVideoRecording immediately after.
BOOL StartVideoRecording(id device, NSString* displayId, VideoMaskPolicy mask,
                          NSDictionary* assetWriterOutputSettings, NSString* outputFile,
                          dispatch_queue_t queue, void (^handler)(NSError*), NSError** error);

// Stops the recording most recently started by StartVideoRecording on this device. Returns NO
// (and sets *error) only for the same synchronous resolution failures StartVideoRecording can hit
// (`handler` is never called in that case); on success, `handler` fires once the output file has
// been finalized on disk. Must not be called before StartVideoRecording's own `handler` has
// already fired — CoreSimulator has no queueing for this and instead surfaces a real,
// empirically-confirmed race to `handler`: NSPOSIXErrorDomain code 22 ("No recording in
// progress"), even though the start call itself separately reports success (see CLAUDE.md).
BOOL StopVideoRecording(id device, dispatch_queue_t queue, void (^handler)(NSError*), NSError** error);

}  // namespace coresim
