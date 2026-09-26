#pragma once

#import <Foundation/Foundation.h>

#include <cstdint>

namespace coresim {

// A live orientation read via a guest-spawned `defaults read` of a backboardd digitizer
// preference (see CLAUDE.md) — reflects a rotation from any source, not just this process's own
// SetDeviceOrientation calls. Costs a guest process spawn (~150ms); not meant to be polled per
// frame. Calls `handler` once, async, with a DeviceOrientation wire value (types.ts) — always 1
// (portrait) on "never rotated this boot" or a spawn/read failure.
void ReadGuestOrientation(id device, void (^handler)(int32_t orientation));

}  // namespace coresim
