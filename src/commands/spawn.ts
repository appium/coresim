import {EventEmitter} from 'node:events';
import {createReadStream, type ReadStream} from 'node:fs';
import {constants as osConstants} from 'node:os';

import type {NativeSimctl} from '../native-simctl.js';
import type {SpawnOptions} from '../types.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    spawnProcess(udid: string, path: string, options?: SpawnOptions): Promise<SpawnedProcess>;
  }
}

// Some signal numbers have more than one name (e.g. SIGABRT/SIGIOT are both 6) — built with a
// for-of rather than Object.fromEntries so the *first* name Node lists for a number wins instead
// of whichever happens to be last, which would otherwise make an aborted process unpredictably
// report as the obscure historical alias (confirmed: this reversed Object.fromEntries reported a
// real SIGABRT as 'SIGIOT').
const SIGNAL_NAME_BY_NUMBER: Record<number, NodeJS.Signals> = {};
for (const [name, num] of Object.entries(osConstants.signals)) {
  SIGNAL_NAME_BY_NUMBER[num] ??= name as NodeJS.Signals;
}

interface SpawnedProcessEvents {
  exit: [code: number | null, signal: NodeJS.Signals | null];
}

/**
 * A process spawned on a simulator device via `NativeSimctl.spawnProcess`. The simulator shares
 * the host kernel and filesystem, so `pid` is a real host OS process id — {@link kill} just calls
 * Node's own `process.kill()`, no native call needed. `stdout`/`stderr` stream live output as the
 * process runs; `'exit'` fires exactly once, with a decoded `(code, signal)` pair mirroring
 * `child_process.ChildProcess`'s own semantics (exactly one of the two is non-null).
 */
export class SpawnedProcess extends EventEmitter<SpawnedProcessEvents> {
  readonly stdout: ReadStream;
  readonly stderr: ReadStream;
  exitCode: number | null = null;
  signalCode: NodeJS.Signals | null = null;

  constructor(
    readonly pid: number,
    stdoutFd: number,
    stderrFd: number,
  ) {
    super();
    this.stdout = createReadStream('', {fd: stdoutFd});
    this.stderr = createReadStream('', {fd: stderrFd});
  }

  /** Whether the process has neither exited nor been killed yet. */
  get running(): boolean {
    return this.exitCode === null && this.signalCode === null;
  }

  /** Sends a signal to the process — a thin wrapper over `process.kill()`. */
  kill(signal: NodeJS.Signals | number = 'SIGTERM'): boolean {
    return process.kill(this.pid, signal);
  }

  /** @internal Invoked once by NativeSimctl when the native termination callback fires. */
  _handleExit(code: number | null, signal: number | null): void {
    this.exitCode = code;
    this.signalCode = signal === null ? null : (SIGNAL_NAME_BY_NUMBER[signal] ?? null);
    this.emit('exit', this.exitCode, this.signalCode);
  }
}

/**
 * Native equivalent of `simctl spawn`. Streams live stdout/stderr and eventually reports an
 * exit code/signal — see {@link SpawnedProcess}.
 *
 * @param udid — UDID of the target device
 * @param path — path to the executable to spawn; not auto-prepended to `options.arguments`
 * @param options — see {@link SpawnOptions}
 * @returns a handle to the spawned process
 */
export async function spawnProcess(
  this: NativeSimctl,
  udid: string,
  path: string,
  options: SpawnOptions = {},
): Promise<SpawnedProcess> {
  return runCatchingAsync(async () => {
    const device = await this._findDevice(udid);
    // The native termination callback can only ever fire once the process has actually started
    // and later exits — strictly after `device.spawn()`'s own promise (which carries the pid)
    // has already resolved below — so `proc` is always assigned by the time this runs.
    let proc: SpawnedProcess;
    const {pid, stdoutFd, stderrFd} = await device.spawn(path, options, (code, signal) =>
      proc._handleExit(code, signal),
    );
    proc = new SpawnedProcess(pid, stdoutFd, stderrFd);
    return proc;
  });
}
