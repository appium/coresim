#pragma once

#import <Foundation/Foundation.h>

namespace coresim {

// Captures the device's main display as a PNG, reading the same in-process framebuffer surface
// `simctl io <udid> screenshot` itself reads (see sim_screenshot.mm) — no temp file, no
// subprocess. Returns nil (and sets *error) if the device has no renderable display surface yet
// (e.g. not booted) or if rendering/encoding failed.
NSData* CaptureScreenshotPNG(id device, NSError** error);

}  // namespace coresim
