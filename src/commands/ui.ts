import type {NativeSimctl} from '../native-simctl.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    getAppearance(udid: string): Promise<number>;
    setAppearance(udid: string, style: number): Promise<void>;
    getIncreaseContrast(udid: string): Promise<number>;
    setIncreaseContrast(udid: string, enabled: boolean): Promise<void>;
    getContentSize(udid: string): Promise<number>;
    setContentSize(udid: string, category: number): Promise<void>;
  }
}

/**
 * @param udid — UDID of the device to read from
 * @returns the device's current UI appearance style, as a raw `UIUserInterfaceStyle` value
 */
export async function getAppearance(this: NativeSimctl, udid: string): Promise<number> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).getUIAppearance());
}

/**
 * @param udid — UDID of the target device
 * @param style — a raw `UIUserInterfaceStyle` value to apply
 */
export async function setAppearance(this: NativeSimctl, udid: string, style: number): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).setUIAppearance(style));
}

/**
 * @param udid — UDID of the device to read from
 * @returns the device's current Increase Contrast accessibility setting
 */
export async function getIncreaseContrast(this: NativeSimctl, udid: string): Promise<number> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).getIncreaseContrast());
}

/**
 * @param udid — UDID of the target device
 * @param enabled — whether Increase Contrast should be enabled
 */
export async function setIncreaseContrast(this: NativeSimctl, udid: string, enabled: boolean): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).setIncreaseContrast(enabled));
}

/**
 * @param udid — UDID of the device to read from
 * @returns the device's current Dynamic Type content size category
 */
export async function getContentSize(this: NativeSimctl, udid: string): Promise<number> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).getContentSize());
}

/**
 * @param udid — UDID of the target device
 * @param category — the Dynamic Type content size category to apply
 */
export async function setContentSize(this: NativeSimctl, udid: string, category: number): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).setContentSize(category));
}
