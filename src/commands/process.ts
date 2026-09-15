import {once} from 'node:events';

import type {NativeSimctl} from '../native-simctl.js';
import type {SimProcessInfo} from '../types.js';
import {runCatchingAsync} from '../utils/index.js';

declare module '../native-simctl.js' {
  interface NativeSimctl {
    listProcesses(udid: string): Promise<SimProcessInfo[]>;
  }
}

/**
 * Lists currently-running processes/launchd jobs on the given (booted) device, by spawning
 * `launchctl list` inside it and parsing its `PID / Status / Label` output. A `-` PID column
 * (registered but not running) is dropped; an app process's `name` is its bundle identifier.
 *
 * @param udid — UDID of the device to inspect; must be booted
 */
export async function listProcesses(this: NativeSimctl, udid: string): Promise<SimProcessInfo[]> {
  return runCatchingAsync(async () => {
    const device = await this._findDevice(udid);
    // The guest runtime ships its own launchctl, distinct from the host's /bin/launchctl (see
    // CLAUDE.md) — spawn() takes a literal path, so resolve it via RuntimeRoot ourselves.
    const launchctlPath = `${device.runtimeRootPath()}/bin/launchctl`;
    const proc = await this.spawnProcess(udid, launchctlPath, {arguments: [launchctlPath, 'list']});
    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk;
    });
    proc.stderr.on('data', (chunk: Buffer) => {
      stderr += chunk;
    });
    // 'exit' can fire before the stdout stream has finished delivering its buffered data (see
    // spawnProcess's own integration test) — wait for both before parsing.
    const [[code, signal]] = await Promise.all([once(proc, 'exit'), once(proc.stdout, 'end')]);
    if (code !== 0) {
      const reason = signal ? `signal ${signal}` : `exit code ${code}`;
      throw new Error(`'launchctl list' failed with ${reason}${stderr.trim() ? `: ${stderr.trim()}` : ''}`);
    }

    const result: SimProcessInfo[] = [];
    for (const line of stdout.split('\n')) {
      const trimmedLine = line.trim();
      if (!trimmedLine) {
        continue;
      }
      const [pidText, , label] = trimmedLine.split(/\s+/);
      const pid = Number.parseInt(pidText, 10);
      if (!pid || !label) {
        continue;
      }
      result.push({pid, group: extractGroup(label), name: extractName(label)});
    }
    return result;
  });
}

function extractGroup(label: string): string | null {
  const colonIdx = label.indexOf(':');
  return colonIdx >= 0 ? label.slice(0, colonIdx) : null;
}

function extractName(label: string): string {
  let name = label.includes(':') ? label.slice(label.indexOf(':') + 1) : label;
  const bracketIdx = name.indexOf('[');
  if (bracketIdx >= 0) {
    name = name.slice(0, bracketIdx);
  }
  return name;
}
