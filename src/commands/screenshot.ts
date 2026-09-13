import type {NativeSimctl} from '../native-simctl.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    getScreenshot(udid: string): Promise<Buffer>;
  }
}

/**
 * Captures the device's main display as a PNG — the native equivalent of `simctl io <udid>
 * screenshot` (see native/sim_screenshot.mm for how this reads the framebuffer directly, with no
 * temp file or subprocess). Rejects if the device has no renderable display surface yet (e.g. not
 * booted).
 *
 * @param udid — UDID of the device to capture; must be booted
 * @returns PNG-encoded image data
 */
export async function getScreenshot(this: NativeSimctl, udid: string): Promise<Buffer> {
  return runCatchingAsync(async () => (await this._findDevice(udid)).screenshot());
}
