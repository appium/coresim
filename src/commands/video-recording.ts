import path from 'node:path';

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

// Tracks which devices currently have an active recording — module-level since the constraint
// (at most one per device) is CoreSimulator's own, not per-NativeSimctl-instance. The value is the
// in-flight (or already-settled) startVideoRecording call, so a concurrent stopVideoRecording can
// always wait for start to fully resolve before racing it natively (see below).
const activeRecordings = new Map<string, Promise<void>>();

/**
 * Starts recording the device's display to `outputFile` — the native equivalent of `simctl io
 * <udid> recordVideo`. Resolves once the first frame has actually been recorded, so it's always
 * safe to call {@link stopVideoRecording} immediately after. Only one recording may be active per
 * device at a time; starting a second one while the first is still running rejects. Rejects with
 * `NativeSimUnavailableError` if this CoreSimulator predates the private capture API — confirmed
 * missing on Xcode 16.4's, present on Xcode 26.5+ (Apple documents no exact version floor).
 *
 * @param udid — UDID of the device to record; must be booted
 * @param outputFile — filesystem path to write the video to; resolved against `process.cwd()` if
 *   relative, since the native layer requires an absolute path
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
  const absoluteOutputFile = path.resolve(outputFile);
  const startPromise = runCatchingAsync(async () =>
    (await this._findDevice(udid)).startVideoRecording(absoluteOutputFile, options),
  );
  // Marked before the native call resolves, not after, so a concurrent startVideoRecording for the
  // same device is rejected immediately instead of racing this one — rolled back below on failure.
  activeRecordings.set(key, startPromise);
  try {
    await startPromise;
  } catch (e) {
    // Only clear our own entry — a concurrent stopVideoRecording (see below) may already have.
    if (activeRecordings.get(key) === startPromise) {
      activeRecordings.delete(key);
    }
    throw e;
  }
}

/**
 * Stops a recording previously started by {@link startVideoRecording} on the same device.
 * Resolves once the video file has been finalized on disk and is safe to read. If `start` is still
 * in flight (e.g. a concurrent caller stopping as soon as {@link isVideoRecording} turns `true`),
 * waits for it to settle first — issuing the native stop call any earlier is a silent CoreSimulator
 * race (see CLAUDE.md).
 *
 * @param udid — UDID of the device to stop recording
 * @throws {Error} if no recording is currently in progress for this device
 */
export async function stopVideoRecording(this: NativeSimctl, udid: string): Promise<void> {
  const key = udid.toLowerCase();
  const pendingStart = activeRecordings.get(key);
  if (!pendingStart) {
    throw new Error(`No video recording is in progress for device '${udid}'`);
  }
  try {
    await pendingStart;
  } catch {
    // start itself failed — its own catch already cleaned up activeRecordings; nothing to stop.
    throw new Error(`No video recording is in progress for device '${udid}'`);
  }
  try {
    await runCatchingAsync(async () => (await this._findDevice(udid)).stopVideoRecording());
  } finally {
    if (activeRecordings.get(key) === pendingStart) {
      activeRecordings.delete(key);
    }
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
