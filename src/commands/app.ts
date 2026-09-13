import type {NativeSimctl} from '../native-simctl.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    installApp(udid: string, appPath: string, options?: Record<string, unknown>): Promise<void>;
    removeApp(udid: string, bundleId: string, options?: Record<string, unknown>): Promise<void>;
    launchApp(udid: string, bundleId: string, options?: Record<string, unknown>): Promise<number>;
    terminateApp(udid: string, bundleId: string): Promise<void>;
    isAppInstalled(udid: string, bundleId: string): Promise<boolean>;
    appInfo(udid: string, bundleId: string): Promise<Record<string, unknown>>;
    installedApps(udid: string): Promise<Record<string, unknown>>;
  }
}

/**
 * Installs an `.app` bundle onto the given device.
 *
 * @param udid — UDID of the target device
 * @param appPath — path to the `.app` bundle on disk
 * @param options — passed through to `installApplication:withOptions:error:`
 */
export async function installApp(
  this: NativeSimctl,
  udid: string,
  appPath: string,
  options: Record<string, unknown> = {},
): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).installApp(appPath, options));
}

/**
 * Uninstalls an app from the given device.
 *
 * @param udid — UDID of the target device
 * @param bundleId — bundle identifier of the app to remove
 * @param options — passed through to `uninstallApplication:withOptions:error:`
 */
export async function removeApp(
  this: NativeSimctl,
  udid: string,
  bundleId: string,
  options: Record<string, unknown> = {},
): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).uninstallApp(bundleId, options));
}

/**
 * Launches an installed app on the given device.
 *
 * @param udid — UDID of the target device
 * @param bundleId — bundle identifier of the app to launch
 * @param options — passed through to `launchApplicationWithID:options:error:`
 * @returns the launched process's pid
 */
export async function launchApp(
  this: NativeSimctl,
  udid: string,
  bundleId: string,
  options: Record<string, unknown> = {},
): Promise<number> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).launchApp(bundleId, options));
}

/**
 * @param udid — UDID of the target device
 * @param bundleId — bundle identifier of the app to terminate
 */
export async function terminateApp(this: NativeSimctl, udid: string, bundleId: string): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).terminateApp(bundleId));
}

/**
 * @param udid — UDID of the device to check
 * @param bundleId — bundle identifier to look up
 * @returns whether an app with that bundle identifier is installed
 */
export async function isAppInstalled(this: NativeSimctl, udid: string, bundleId: string): Promise<boolean> {
  return runCatchingAsync(async () => bundleId in (await (await this._findDevice(udid)).installedApps()));
}

/**
 * @param udid — UDID of the device to read from
 * @param bundleId — bundle identifier of the installed app
 * @returns the app's properties, as reported by `propertiesOfApplication:`
 */
export async function appInfo(this: NativeSimctl, udid: string, bundleId: string): Promise<Record<string, unknown>> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).propertiesOfApplication(bundleId));
}

/**
 * @param udid — UDID of the device to read from
 * @returns every installed app's properties, keyed by bundle identifier
 */
export async function installedApps(this: NativeSimctl, udid: string): Promise<Record<string, unknown>> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).installedApps());
}
