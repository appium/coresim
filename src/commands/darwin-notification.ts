import type {NativeSimctl} from '../native-simctl.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    getDarwinNotificationState(udid: string, name: string): Promise<number>;
    setDarwinNotificationState(udid: string, name: string, state: number): Promise<void>;
    postDarwinNotification(udid: string, name: string): Promise<void>;
  }
}

/**
 * The "state" here is Darwin's low-level `notify(3)` per-name state value (`notify_get_state`) —
 * a 64-bit integer any process can attach to a notification name independently of posting it, so
 * a reader can check the last-set value without having been listening at post time.
 *
 * @see https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/notify.3.html
 * @param udid — UDID of the device to read from
 * @param name — Darwin notification name
 * @returns the last-set state value for that notification (`0` if never set)
 */
export async function getDarwinNotificationState(this: NativeSimctl, udid: string, name: string): Promise<number> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).darwinNotificationGetState(name));
}

/**
 * Sets the state value of a Darwin notification on the given device, without posting it (see
 * {@link getDarwinNotificationState} for what "state" means here — `notify(3)`'s `notify_set_state`).
 *
 * @param udid — UDID of the target device
 * @param name — Darwin notification name
 * @param state — state value to store
 */
export async function setDarwinNotificationState(
  this: NativeSimctl,
  udid: string,
  name: string,
  state: number,
): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).darwinNotificationSetState(name, state));
}

/**
 * @param udid — UDID of the target device
 * @param name — Darwin notification name to post
 */
export async function postDarwinNotification(this: NativeSimctl, udid: string, name: string): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).postDarwinNotification(name));
}
