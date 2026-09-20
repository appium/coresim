import {EventEmitter, on} from 'node:events';

import {logger} from '@appium/support';

import {wrapNativeError} from '../errors.js';
import type {NativeSimctl} from '../native-simctl.js';
import type {NativeVideoStreamHandle, VideoAccessUnit, VideoStreamOptions} from '../types.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    startVideoStream(udid: string, options?: VideoStreamOptions): Promise<VideoStream>;
  }
}

const log = logger.getLogger('CoreSim');

/** `wrapNativeError` always throws — this just gets its thrown value back as a plain return, to emit rather than raise it. */
function toTypedError(err: unknown): Error {
  try {
    wrapNativeError(err);
  } catch (wrapped) {
    return wrapped as Error;
  }
}

/**
 * A live video stream from `NativeSimctl.startVideoStream` — encodes the device's display in real
 * time via VideoToolbox, unlike `startVideoRecording`, which drives CoreSimulator's own private,
 * file-only recorder. Mirrors `appium-ios-remotexpc`'s `ScreenStreamCapture` shape
 * (`accessUnits()`/`stop()`) for API consistency; the transport is otherwise unrelated.
 */
export class VideoStream extends EventEmitter {
  private handle: NativeVideoStreamHandle | undefined;
  private readonly stopController = new AbortController();
  private stopPromise: Promise<void> | undefined;

  /** @internal */
  constructor(public readonly codec: 'h264' | 'hevc') {
    super();
  }

  /** @internal */
  _handleAccessUnit(unit: VideoAccessUnit): void {
    this.emit('accessUnit', unit);
  }

  /**
   * @internal
   * `EventEmitter` throws (crashing the process) if `emit('error', ...)` has no listener — but an
   * active `accessUnits()` consumer counts as one (`events.on()` registers its own internally), so
   * this only needs to fall back to logging when nobody is actually able to observe the error.
   */
  _handleError(err: unknown): void {
    const error = toTypedError(err);
    if (this.listenerCount('error') > 0) {
      this.emit('error', error);
    } else {
      log.error(`Unhandled VideoStream error: ${error.stack ?? error}`);
    }
  }

  /** @internal */
  _attachHandle(handle: NativeVideoStreamHandle): void {
    this.handle = handle;
  }

  /**
   * Yields each encoded access unit as it's produced, until {@link stop} is called or the stream
   * errors (in which case the error is thrown out of the loop). Pass `signal` to stop iterating
   * without treating that as an error. Mirrors `ScreenStreamCapture.accessUnits()`'s shape.
   */
  async *accessUnits(signal?: AbortSignal): AsyncGenerator<VideoAccessUnit> {
    const combined = signal ? AbortSignal.any([signal, this.stopController.signal]) : this.stopController.signal;
    try {
      // on() itself throws synchronously if `combined` is already aborted — kept inside this try
      // (not hoisted above it) so that case returns cleanly like an abort during iteration does.
      const events = on(this, 'accessUnit', {signal: combined});
      for await (const [unit] of events) {
        yield unit as VideoAccessUnit;
      }
    } catch (err) {
      if (combined.aborted) {
        return;
      }
      throw err;
    }
  }

  /** Stops the stream and releases the underlying encoder. Idempotent, including concurrently. */
  async stop(): Promise<void> {
    this.stopPromise ??= (async () => {
      this.stopController.abort();
      await this.handle?.stop();
    })();
    return this.stopPromise;
  }
}

/**
 * Starts encoding the device's display in real time. Resolves once the encoder has actually
 * started; the returned {@link VideoStream}'s `accessUnits()` then yields each frame as it
 * arrives. Independent of `startVideoRecording`/`stopVideoRecording` — both, and any number of
 * concurrent streams, can run on the same device at once.
 *
 * @param udid — UDID of the device to stream; must be booted
 * @param options — `displayId`, `codec`, `fps`, `bitrate` — see {@link VideoStreamOptions}
 */
export async function startVideoStream(
  this: NativeSimctl,
  udid: string,
  options: VideoStreamOptions = {},
): Promise<VideoStream> {
  if (options.fps !== undefined && (!Number.isFinite(options.fps) || options.fps <= 0)) {
    throw new RangeError(`fps must be a positive finite number, got ${options.fps}`);
  }
  if (
    options.bitrate !== undefined &&
    (!Number.isFinite(options.bitrate) || options.bitrate <= 0 || options.bitrate > 2 ** 31 - 1)
  ) {
    throw new RangeError(`bitrate must be a positive number no greater than ${2 ** 31 - 1}, got ${options.bitrate}`);
  }
  const device = await runCatchingAsync(() => this._findDevice(udid));
  const stream = new VideoStream(options.codec === 'hevc' ? 'hevc' : 'h264');
  const handle = await runCatchingAsync(() =>
    device.startVideoStream(
      options,
      (unit) => stream._handleAccessUnit(unit),
      (err) => stream._handleError(err),
    ),
  );
  stream._attachHandle(handle);
  return stream;
}
