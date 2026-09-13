import type {NativeSimctl} from '../native-simctl.js';
import type {SimPermissionService} from '../types.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    grantPermission(udid: string, service: SimPermissionService, bundleId: string): Promise<void>;
    revokePermission(udid: string, service: SimPermissionService, bundleId: string): Promise<void>;
    resetPermission(udid: string, service: SimPermissionService, bundleId: string): Promise<void>;
  }
}

/**
 * Grants a privacy permission to the given app on the given device, by writing directly to the
 * simulator's own TCC (privacy) database — see CLAUDE.md for why this bypasses CoreSimulator's own
 * privacy API.
 *
 * @param udid — UDID of the target device
 * @param service — permission to grant, e.g. `"camera"`, `"contacts"`, `"photos"`
 * @param bundleId — bundle identifier of the app the permission applies to
 */
export async function grantPermission(
  this: NativeSimctl,
  udid: string,
  service: SimPermissionService,
  bundleId: string,
): Promise<void> {
  return runCatchingAsync(async () => {
    const tccIdentifier = toTCCIdentifier(service);
    return (await this._findDevice(udid)).grantPermission(tccIdentifier, bundleId);
  });
}

/**
 * Revokes a previously granted privacy permission from the given app.
 *
 * @param udid — UDID of the target device
 * @param service — permission to revoke (see {@link grantPermission})
 * @param bundleId — bundle identifier of the app the permission applies to
 */
export async function revokePermission(
  this: NativeSimctl,
  udid: string,
  service: SimPermissionService,
  bundleId: string,
): Promise<void> {
  return runCatchingAsync(async () => {
    const tccIdentifier = toTCCIdentifier(service);
    return (await this._findDevice(udid)).revokePermission(tccIdentifier, bundleId);
  });
}

/**
 * Resets a privacy permission for the given app to its default (unprompted) state.
 *
 * @param udid — UDID of the target device
 * @param service — permission to reset (see {@link grantPermission})
 * @param bundleId — bundle identifier of the app the permission applies to
 */
export async function resetPermission(
  this: NativeSimctl,
  udid: string,
  service: SimPermissionService,
  bundleId: string,
): Promise<void> {
  return runCatchingAsync(async () => {
    const tccIdentifier = toTCCIdentifier(service);
    return (await this._findDevice(udid)).resetPermission(tccIdentifier, bundleId);
  });
}

// Maps a friendly service name to the internal TCC service identifier its row in the simulator's
// own TCC.db is keyed on (see native/tcc_privacy.h). `location` is deliberately absent: it isn't a
// plain TCC row (CoreLocation simulation has its own subsystem), so it isn't supported by this
// TCC.db-based implementation.
const SERVICE_TO_TCC_IDENTIFIER: Record<SimPermissionService, string> = {
  calendar: 'kTCCServiceCalendar',
  camera: 'kTCCServiceCamera',
  contacts: 'kTCCServiceAddressBook',
  health: 'kTCCServiceMSO',
  homekit: 'kTCCServiceWillow',
  medialibrary: 'kTCCServiceMediaLibrary',
  microphone: 'kTCCServiceMicrophone',
  motion: 'kTCCServiceMotion',
  photos: 'kTCCServicePhotos',
  reminders: 'kTCCServiceReminders',
  siri: 'kTCCServiceSiri',
  speech: 'kTCCServiceSpeechRecognition',
};

function toTCCIdentifier(service: SimPermissionService): string {
  const identifier = SERVICE_TO_TCC_IDENTIFIER[service];
  if (!identifier) {
    throw new Error(
      `'${service}' is not a supported permission. Supported: ${Object.keys(SERVICE_TO_TCC_IDENTIFIER).join(', ')}`,
    );
  }
  return identifier;
}
