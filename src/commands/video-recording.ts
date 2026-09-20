import type {NativeSimctl} from '../native-simctl.js';
import type {VideoRecordingOptions} from '../types.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    startVideoRecording(udid: string, outputFile: string, options?: VideoRecordingOptions): Promise<void>;
    stopVideoRecording(udid: string): Promise<void>;
    isVideoRecording(udid: string): Promise<boolean>;
  }
}

// Tracks which devices currently have an active recording. Module-level (not per-NativeSimctl
// instance) since the constraint this enforces is CoreSimulator's own: at most one recording per
// device at a time, regardless of which NativeSimctl instance asked for it. Keyed by lowercased
// UDID, matching `_findDevice`'s own case-insensitive comparison.
const activeRecordings = new Set<string>();

/**
 * Starts recording the device's display to `outputFile` — the native equivalent of `simctl io
 * <udid> recordVideo` (see native/sim_video_recording.mm for how this drives CoreSimulator's own
 * frame-capture-and-encode pipeline directly, with no subprocess and no manual encoding on this
 * addon's side). Resolves once the first frame has actually been recorded — mirroring `simctl`'s
 * own "Recording started" signal — so it's always safe to call {@link stopVideoRecording}
 * immediately after this resolves.
 *
 * Only one recording may be active per device at a time; starting a second one while the first is
 * still running rejects instead of silently replacing it.
 *
 * @param udid — UDID of the device to record; must be booted
 * @param outputFile — absolute filesystem path the video should be written to (the parent
 * directory must already exist; CoreSimulator itself creates/writes the file, not this addon)
 * @param options — `displayId`, `codec`, `mask` — see {@link VideoRecordingOptions}
 * @throws {Error} if a recording is already in progress for this device
 */
export async function startVideoRecording(
  this: NativeSimctl,
  udid: string,
  outputFile: string,
  options: VideoRecordingOptions = {},
): Promise<void> {
  const key = udid.toLowerCase();
  if (activeRecordings.has(key)) {
    throw new Error(`A video recording is already in progress for device '${udid}'`);
  }
  activeRecordings.add(key);
  try {
    await runCatchingAsync(async () => (await this._findDevice(udid)).startVideoRecording(outputFile, options));
  } catch (e) {
    activeRecordings.delete(key);
    throw e;
  }
}

/**
 * Stops a recording previously started by {@link startVideoRecording} on the same device.
 * Resolves once the video file has been finalized on disk and is safe to read.
 *
 * @param udid — UDID of the device to stop recording
 * @throws {Error} if no recording is currently in progress for this device
 */
export async function stopVideoRecording(this: NativeSimctl, udid: string): Promise<void> {
  const key = udid.toLowerCase();
  if (!activeRecordings.has(key)) {
    throw new Error(`No video recording is in progress for device '${udid}'`);
  }
  try {
    await runCatchingAsync(async () => (await this._findDevice(udid)).stopVideoRecording());
  } finally {
    activeRecordings.delete(key);
  }
}

/**
 * Whether a recording started by {@link startVideoRecording} is currently active for this device.
 * Pure local state — no CoreSimulator dispatch — so this never rejects with a native error.
 *
 * @param udid — UDID of the device to check
 */
export async function isVideoRecording(this: NativeSimctl, udid: string): Promise<boolean> {
  return activeRecordings.has(udid.toLowerCase());
}
