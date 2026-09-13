#pragma once

#import <Foundation/Foundation.h>

namespace coresim {

// Grants or revokes a privacy permission for `bundleId` in the simulator's own TCC (privacy)
// database, located under the device's data directory (see DeviceDataPath, sim_device.h) at
// `Library/TCC/TCC.db`. `service` is the raw TCC service identifier (e.g. "kTCCServiceCamera"),
// not a friendly name — callers map friendly names to these before calling in (see
// commands/permissions.ts). Fails with a descriptive NSError if the device has never been booted
// (TCC.db doesn't exist yet) or the database can't be written to.
BOOL SetTCCAccess(NSString* dataPath, NSString* service, NSString* bundleId, BOOL granted, NSError** error);

// Resets a previously granted/revoked permission back to its default (unprompted, "unset") state
// by deleting its row from TCC.db, if one exists.
BOOL ResetTCCAccess(NSString* dataPath, NSString* service, NSString* bundleId, NSError** error);

}  // namespace coresim
