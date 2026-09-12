import type {NativeSimctl} from '../native-simctl.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    grantPermission(udid: string, service: string, bundleId: string): Promise<void>;
    revokePermission(udid: string, service: string, bundleId: string): Promise<void>;
    resetPermission(udid: string, service: string, bundleId: string): Promise<void>;
  }
}

/**
 * Grants a privacy permission to the given app on the given device.
 *
 * @param udid — UDID of the target device
 * @param service — permission to grant, e.g. `"location"`, `"contacts"`, `"photos"`
 * @param bundleId — bundle identifier of the app the permission applies to
 */
export async function grantPermission(
  this: NativeSimctl,
  udid: string,
  service: string,
  bundleId: string,
): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).grantPermission(service, bundleId));
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
  service: string,
  bundleId: string,
): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).revokePermission(service, bundleId));
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
  service: string,
  bundleId: string,
): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).resetPermission(service, bundleId));
}
