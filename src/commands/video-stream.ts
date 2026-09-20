import {EventEmitter, on} from 'node:events';

import {wrapNativeError} from '../errors.js';
import type {NativeSimctl} from '../native-simctl.js';
import type {NativeVideoStreamHandle, VideoAccessUnit, VideoStreamOptions} from '../types.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    startVideoStream(udid: string, options?: VideoStreamOptions): Promise<VideoStream>;
  }
}

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
 * time via VideoToolbox (see native/sim_video_stream.mm), unlike `startVideoRecording`, which
 * drives CoreSimulator's own private, file-only recorder.
 *
 * Mirrors the `start()`/`accessUnits()`/`stop()` shape `appium-ios-remotexpc`'s own
 * `ScreenStreamCapture` uses for real-device streaming, for API consistency — though the two are
 * otherwise unrelated: that reads an RTP feed the device's own hardware encoder produces over the
 * network; this reads the Simulator's live framebuffer in-process and encodes it itself.
 */
export class VideoStream extends EventEmitter {
  private handle: NativeVideoStreamHandle | undefined;
  private stopped = false;

  /** @internal */
  constructor(public readonly codec: 'h264' | 'hevc') {
    super();
    // Without a baseline listener, emit('error', ...) below crashes the whole process (Node's
    // EventEmitter default behavior) whenever it fires while nobody's actively consuming
    // accessUnits() yet — e.g. right after startVideoStream() resolves, before the caller's own
    // `for await` loop has started. accessUnits()'s own `on()`-based listener (added once
    // consumption starts) still receives and throws every error into the generator as documented;
    // this only exists to make emitting one always safe, never to swallow it from an active
    // consumer.
    this.on('error', () => {});
  }

  /** @internal */
  _handleAccessUnit(unit: VideoAccessUnit): void {
    this.emit('accessUnit', unit);
  }

  /** @internal */
  _handleError(err: unknown): void {
    this.emit('error', toTypedError(err));
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
    const events = on(this, 'accessUnit', {signal});
    try {
      for await (const [unit] of events) {
        yield unit as VideoAccessUnit;
      }
    } catch (err) {
      if (signal?.aborted) {
        return;
      }
      throw err;
    }
  }

  /** Stops the stream and releases the underlying encoder. Idempotent. */
  async stop(): Promise<void> {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    await this.handle?.stop();
  }
}

/**
 * Starts encoding the device's display in real time and streaming it as it's produced — unlike
 * {@link NativeSimctl.startVideoRecording}, which drives CoreSimulator's own private, file-only
 * recorder, this reads the same live framebuffer directly and encodes it itself via VideoToolbox
 * (see native/sim_video_stream.mm), so it can deliver access units live instead of only ever
 * producing a finished file. Resolves once the encoder has actually started; the returned
 * {@link VideoStream}'s `accessUnits()` then yields each encoded frame as it arrives.
 *
 * Independent of `startVideoRecording`/`stopVideoRecording` — both can run concurrently on the
 * same device, and there's no limit on the number of concurrent streams.
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
