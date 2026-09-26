import type {NativeSimctl} from '../native-simctl.js';
import type {DeviceOrientation} from '../types.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    getAppearance(udid: string): Promise<number>;
    setAppearance(udid: string, style: number): Promise<void>;
    getIncreaseContrast(udid: string): Promise<number>;
    setIncreaseContrast(udid: string, enabled: boolean): Promise<void>;
    getContentSize(udid: string): Promise<number>;
    setContentSize(udid: string, category: number): Promise<void>;
    setOrientation(udid: string, orientation: DeviceOrientation): Promise<void>;
    isPortraitOrientation(udid: string): Promise<boolean>;
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

/**
 * Rotates the device — the same effect as Simulator.app's Hardware > Rotate menu items. Write-only
 * (no reliable read-back exists) and known to silently no-op in two cases — see CLAUDE.md's "Known
 * gaps": a device-motion-capable runtime, and a device this same process both created and booted.
 *
 * @param udid — UDID of the target device
 * @param orientation — the orientation to rotate to
 */
export async function setOrientation(this: NativeSimctl, udid: string, orientation: DeviceOrientation): Promise<void> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).setOrientation(orientation));
}

/**
 * Whether the device's screen is currently portrait-shaped (width <= height) — a dimension
 * heuristic, since there's no reliable orientation-read API (see CLAUDE.md). true for a square
 * screenshot, false only when strictly wider than tall.
 *
 * Captures via the same active mechanism `simctl io <udid> screenshot` uses — unlike
 * {@link getScreenshot}'s fast in-process read, this correctly reflects a live device rotation, at
 * the cost of a much slower (~1s) call (see CLAUDE.md).
 *
 * @param udid — UDID of the device to inspect; must be booted
 */
export async function isPortraitOrientation(this: NativeSimctl, udid: string): Promise<boolean> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).isPortraitOrientation());
}
