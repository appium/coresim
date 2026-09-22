import {EventEmitter} from 'node:events';

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

// Matches the native side's own ThreadSafeFunction queue bound (see coresim.mm's
// kAccessUnitQueueSize) — kept here too since the native bound alone provides no real
// backpressure: _handleAccessUnit's emit-equivalent push always returns immediately, regardless of
// how slow the actual accessUnits() consumer is, so without a bound of its own this queue could
// otherwise grow without limit while a slow consumer falls behind.
const MAX_BUFFERED_UNITS = 60;

const SINGLE_CONSUMER_ERROR =
  'VideoStream.accessUnits() supports only one active consumer at a time — a second concurrent call rejects.';

/** `wrapNativeError` always throws — this just gets its thrown value back as a plain return, to emit rather than raise it. */
function toTypedError(err: unknown): Error {
  try {
    wrapNativeError(err);
  } catch (wrapped) {
    return wrapped as Error;
  }
}

/**
 * Single-consumer FIFO between native's per-frame callback and `accessUnits()`. Unlike routing
 * through `EventEmitter`, a unit pushed before any consumer has started iterating is retained
 * (fixing the encoder's own first-frame/keyframe otherwise being lost to a startup race) rather
 * than silently dropped.
 *
 * Bounded at `MAX_BUFFERED_UNITS`, but codec-aware about *how* it sheds load once a slow consumer
 * falls behind: since frames only reference earlier frames they were encoded against (no
 * `AllowFrameReordering`), dropping an arbitrary interframe would orphan every later one from its
 * reference chain, corrupting decode from that point on even though delivery looks unbroken.
 * Overflow instead clears the backlog entirely and enters a resync state, discarding every
 * further interframe (not buffering them) until the next keyframe — self-decodable on its own —
 * lets delivery resume cleanly.
 */
class AccessUnitQueue {
  private readonly buffer: VideoAccessUnit[] = [];
  private waiter:
    | {resolve: (result: IteratorResult<VideoAccessUnit>) => void; reject: (err: unknown) => void}
    | undefined;
  private ended = false;
  private error: unknown;
  private resyncing = false;

  /** @param onOverflow — called once when overflow first forces a resync, e.g. to request a fresh keyframe. */
  constructor(private readonly onOverflow?: () => void) {}

  push(unit: VideoAccessUnit): void {
    if (this.ended) {
      return;
    }
    if (this.resyncing) {
      if (!unit.isKeyFrame) {
        return; // still waiting for a self-decodable point to resume delivery from
      }
      this.resyncing = false;
    }
    if (this.waiter) {
      const {resolve} = this.waiter;
      this.waiter = undefined;
      resolve({value: unit, done: false});
      return;
    }
    this.buffer.push(unit);
    if (this.buffer.length > MAX_BUFFERED_UNITS) {
      this.buffer.length = 0;
      this.resyncing = true;
      this.onOverflow?.();
    }
  }

  /** Ends the queue with an error — any pending or future `next()` rejects with it. */
  fail(err: unknown): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.error = err;
    this.buffer.length = 0;
    if (this.waiter) {
      const {reject} = this.waiter;
      this.waiter = undefined;
      reject(err);
    }
  }

  /** Ends the queue cleanly — any pending or future `next()` resolves `done`. */
  end(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.buffer.length = 0;
    if (this.waiter) {
      const {resolve} = this.waiter;
      this.waiter = undefined;
      resolve({value: undefined, done: true});
    }
  }

  /**
   * Resolves `done` (not rejects) if `signal` aborts while waiting, mirroring `events.on()`.
   * Checks cancellation/end *before* dequeuing, so an already-aborted signal or an already-ended
   * queue never hands out a stale buffered unit — an aborted consumer, or a fresh iterator started
   * after `stop()`, must see the boundary immediately rather than draining leftovers first.
   */
  next(signal: AbortSignal): Promise<IteratorResult<VideoAccessUnit>> {
    if (signal.aborted) {
      return Promise.resolve({value: undefined, done: true});
    }
    if (this.ended) {
      return this.error ? Promise.reject(this.error) : Promise.resolve({value: undefined, done: true});
    }
    const buffered = this.buffer.shift();
    if (buffered !== undefined) {
      return Promise.resolve({value: buffered, done: false});
    }
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        this.waiter = undefined;
        resolve({value: undefined, done: true});
      };
      signal.addEventListener('abort', onAbort, {once: true});
      this.waiter = {
        resolve: (result) => {
          signal.removeEventListener('abort', onAbort);
          resolve(result);
        },
        reject: (err) => {
          signal.removeEventListener('abort', onAbort);
          reject(err);
        },
      };
    });
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
  // Requests a fresh keyframe on resync so delivery can resume immediately rather than waiting
  // for the next periodic one — `handle` may not be attached yet on a startup-time overflow
  // (vanishingly unlikely given MAX_BUFFERED_UNITS), in which case this is just a no-op.
  private readonly queue = new AccessUnitQueue(() => this.handle?.requestKeyFrame());
  private activeConsumers = 0;

  /** @internal */
  constructor(public readonly codec: 'h264' | 'hevc') {
    super();
  }

  /** @internal */
  _handleAccessUnit(unit: VideoAccessUnit): void {
    this.queue.push(unit);
  }

  /**
   * @internal
   * An active `accessUnits()` consumer receives the error via the queue itself (thrown out of its
   * `for await` loop, per that method's contract) rather than the `'error'` event, so `emit` is
   * only used for an explicit external listener; with neither, it's logged instead of lost.
   */
  _handleError(err: unknown): void {
    const error = toTypedError(err);
    this.queue.fail(error);
    if (this.listenerCount('error') > 0) {
      this.emit('error', error);
    } else if (this.activeConsumers === 0) {
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
   *
   * Only one active consumer is supported at a time — a second concurrent call rejects rather
   * than silently sharing (and corrupting) the first one's single internal waiter slot.
   */
  async *accessUnits(signal?: AbortSignal): AsyncGenerator<VideoAccessUnit> {
    if (this.activeConsumers > 0) {
      throw new Error(SINGLE_CONSUMER_ERROR);
    }
    const combined = signal ? AbortSignal.any([signal, this.stopController.signal]) : this.stopController.signal;
    this.activeConsumers++;
    try {
      for (;;) {
        const result = await this.queue.next(combined);
        if (result.done) {
          return;
        }
        yield result.value;
      }
    } finally {
      this.activeConsumers--;
    }
  }

  /** Stops the stream and releases the underlying encoder. Idempotent, including concurrently. */
  async stop(): Promise<void> {
    this.stopPromise ??= (async () => {
      this.stopController.abort();
      this.queue.end();
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
  // The native poller clamps below 1 fps to 1 fps rather than actually polling that slowly, so a
  // sub-1 value here would silently poll far more often than requested — rejected instead.
  if (options.fps !== undefined && (!Number.isFinite(options.fps) || options.fps < 1)) {
    throw new RangeError(`fps must be a finite number >= 1, got ${options.fps}`);
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
