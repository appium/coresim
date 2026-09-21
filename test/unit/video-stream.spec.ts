import assert from 'node:assert';
import {describe, it} from 'node:test';

import {VideoStream} from '../../src/index.js';
import type {VideoAccessUnit} from '../../src/index.js';

function fakeUnit(sequence: number): VideoAccessUnit {
  return {data: Buffer.from([sequence]), isKeyFrame: sequence === 0, sequence, timestampMicros: sequence * 1000};
}

/**
 * Pure JS-level coverage of `VideoStream`'s buffering/lifecycle, exercised via its `@internal`
 * methods (the same ones `coresim.mm`'s native glue calls) — no simulator or native addon needed.
 * Mutating/native-backed coverage lives under test/integration instead.
 */
describe('VideoStream', () => {
  it('retains an access unit produced before any consumer starts iterating', async () => {
    const stream = new VideoStream('h264');
    // Simulate the encoder's very first (keyframe) callback firing before the caller has had a
    // chance to call accessUnits() — see CLAUDE.md for why this race is real, not hypothetical.
    stream._handleAccessUnit(fakeUnit(0));

    const it1 = stream.accessUnits();
    const {value, done} = await it1.next();
    assert.strictEqual(done, false);
    assert.strictEqual(value?.sequence, 0);
    assert.strictEqual(value?.isKeyFrame, true);
    await stream.stop();
  });

  it('bounds its buffer, dropping the oldest units once the limit is exceeded', async () => {
    const stream = new VideoStream('h264');
    // One more than the queue's internal bound so the very oldest (sequence 0) must be dropped.
    for (let i = 0; i < 61; i++) {
      stream._handleAccessUnit(fakeUnit(i));
    }
    const received: number[] = [];
    for await (const unit of stream.accessUnits()) {
      received.push(unit.sequence);
      if (received.length === 60) {
        break;
      }
    }
    assert.strictEqual(received.length, 60);
    assert.strictEqual(received[0], 1, 'the oldest unit (sequence 0) should have been dropped');
    assert.strictEqual(received[59], 60);
    await stream.stop();
  });

  it('returns cleanly from accessUnits() given an already-aborted signal', async () => {
    const stream = new VideoStream('h264');
    const controller = new AbortController();
    controller.abort();
    const received: VideoAccessUnit[] = [];
    for await (const unit of stream.accessUnits(controller.signal)) {
      received.push(unit);
    }
    assert.strictEqual(received.length, 0);
    await stream.stop();
  });

  it('returns cleanly from accessUnits() called after stop()', async () => {
    const stream = new VideoStream('h264');
    await stream.stop();
    const received: VideoAccessUnit[] = [];
    for await (const unit of stream.accessUnits()) {
      received.push(unit);
    }
    assert.strictEqual(received.length, 0);
  });

  it('resolves both callers of a concurrent stop()', async () => {
    const stream = new VideoStream('h264');
    await Promise.all([stream.stop(), stream.stop()]);
  });

  it('throws an error into an active accessUnits() consumer', async () => {
    const stream = new VideoStream('h264');
    const iterating = (async () => {
      const received: VideoAccessUnit[] = [];
      for await (const unit of stream.accessUnits()) {
        received.push(unit);
      }
      return received;
    })();
    stream._handleAccessUnit(fakeUnit(0));
    stream._handleError(new Error('synthetic encoder failure'));
    await assert.rejects(iterating, /synthetic encoder failure/);
  });

  it('emits "error" when an explicit listener is attached', async () => {
    const stream = new VideoStream('h264');
    const received = new Promise<Error>((resolve) => stream.once('error', resolve));
    stream._handleError(new Error('synthetic error, with listener'));
    const error = await received;
    assert.match(error.message, /synthetic error, with listener/);
  });

  it('does not crash when an error occurs with no listener and no active consumer', () => {
    const stream = new VideoStream('h264');
    assert.doesNotThrow(() => stream._handleError(new Error('synthetic error, nobody listening')));
  });
});
