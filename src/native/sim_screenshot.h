#pragma once

#import <Foundation/Foundation.h>

namespace coresim {

// Enumerates the device's renderable display IO ports — the same information `simctl io <udid>
// enumerate` reports for its own `--display` selection. Each element has "id" (NSString, a port
// UUID — pass to CaptureScreenshot's displayId to target it), "displayClass" (NSNumber,
// unsigned short — 0 is always the primary display), and "isMain" (NSNumber/BOOL). Returns nil
// (and sets *error) if the device has no IO client at all (e.g. not booted); an empty (non-nil)
// array means the device has an IO client but no renderable display.
NSArray<NSDictionary*>* ListDisplays(id device, NSError** error);

// Resolves the renderable display descriptor CaptureScreenshot itself reads from, without also
// capturing a screenshot — exposed (beyond CaptureScreenshot/ListDisplays) for
// sim_video_recording.mm's StartVideoRecording, which needs the same descriptor object as its own
// `screen` argument. Same displayId/fallback semantics as CaptureScreenshot (see below).
id ResolveCaptureDisplay(id device, NSString* displayId, NSError** error);

// The display descriptor's current framebuffer, as an `IOSurfaceRef` (bridge-cast the returned
// `id`) — the same surface CaptureScreenshot itself reads. Exposed for sim_video_stream.mm, which
// polls it repeatedly rather than reading it once. Returns nil if the surface isn't available yet
// (e.g. the connection just dropped) — not an error, since that can legitimately happen from one
// call to the next on a live device.
id CurrentDisplaySurface(id descriptor);

enum class ScreenshotFormat { kPNG, kJPEG };

// Captures a display as an image, reading the same in-process framebuffer surface `simctl io
// <udid> screenshot` itself reads (see sim_screenshot.mm) — no temp file, no subprocess.
// `displayId`, if non-nil, selects a specific port by its UUID (see ListDisplays); nil selects the
// primary display (displayClass 0), falling back to the first renderable display found (e.g. for
// tvOS, which has no class-0 display). `jpegQualityPercent` (0-100, nil for ImageIO's own default)
// only applies when `format` is kJPEG — ignored for kPNG, which is always lossless. Returns nil
// (and sets *error) if `displayId` doesn't match any port, the resolved display has no renderable
// surface yet (e.g. not booted), or rendering/encoding failed.
NSData* CaptureScreenshot(id device, NSString* displayId, ScreenshotFormat format, NSNumber* jpegQualityPercent,
                          NSError** error);

}  // namespace coresim
