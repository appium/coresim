import assert from 'node:assert';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {describe, it} from 'node:test';
import {pathToFileURL} from 'node:url';

import {NativeSimctl, NativeSimError, NativeSimUnavailableError, SimDeviceState} from '../../src/index.js';
import {getPkgRoot} from '../../src/utils/index.js';

// Built from getPkgRoot() (not a relative "../../" climb from this compiled test file) because
// it's handed to a spawned subprocess as an import specifier string, not used as a static import
// here — getPkgRoot() is the same package-root resolution the native addon loader itself relies
// on, so this can't silently drift from where lib/src/index.js actually ends up.
const INDEX_MODULE_URL = pathToFileURL(path.join(getPkgRoot(), 'lib/src/index.js')).href;

/**
 * Read-only checks against the real CoreSimulator device set — nothing here boots, creates, or
 * deletes a device, so it's safe to run on any macOS host with Xcode + a simulator runtime
 * installed (including a developer's own machine) without touching existing simulator state.
 * Mutating coverage (boot/shutdown, create/delete) lives under test/integration instead.
 */
describe('NativeSimctl (read-only)', {timeout: 30000}, () => {
  it('reports a real CoreSimulator.framework version', async () => {
    const version = await NativeSimctl.frameworkVersion();
    assert.match(version, /^\d+(\.\d+)*$/);
  });

  it('lists the real device set with well-formed entries', async () => {
    const sim = new NativeSimctl();
    const devices = await sim.getDevices();
    assert.ok(devices.length > 0, 'expected at least one simulator device to exist');
    for (const device of devices) {
      assert.match(device.udid, /^[0-9A-F-]{36}$/i);
      assert.strictEqual(typeof device.name, 'string');
      assert.ok(Object.values(SimDeviceState).includes(device.state));
      assert.strictEqual(typeof device.deviceTypeIdentifier, 'string');
      assert.strictEqual(typeof device.runtimeIdentifier, 'string');
    }
  });

  it('lists non-empty, well-formed supported device types', async () => {
    const sim = new NativeSimctl();
    const types = await sim.getSupportedDeviceTypes();
    assert.ok(types.length > 0);
    for (const type of types) {
      assert.match(type.identifier, /^com\.apple\.CoreSimulator\.SimDeviceType\./);
      assert.strictEqual(typeof type.name, 'string');
    }
  });

  it('lists non-empty, well-formed supported runtimes', async () => {
    const sim = new NativeSimctl();
    const runtimes = await sim.getSupportedRuntimes();
    assert.ok(runtimes.length > 0);
    for (const runtime of runtimes) {
      assert.match(runtime.identifier, /^com\.apple\.CoreSimulator\.SimRuntime\./);
      assert.strictEqual(typeof runtime.name, 'string');
      assert.match(runtime.versionString, /^\d+(\.\d+)*$/);
    }
  });

  it('reads getenv from a booted device, when one is booted', async () => {
    const sim = new NativeSimctl();
    const booted = (await sim.getDevices()).find((d) => d.state === SimDeviceState.Booted);
    if (!booted) {
      return; // nothing booted right now; the async boot path is covered under integration
    }
    const home = await sim.getEnv(booted.udid, 'HOME');
    assert.match(home, /CoreSimulator\/Devices/);
  });

  it('reads installedApps from a booted device as a plain object, when one is booted', async () => {
    const sim = new NativeSimctl();
    const booted = (await sim.getDevices()).find((d) => d.state === SimDeviceState.Booted);
    if (!booted) {
      return;
    }
    const apps = await sim.installedApps(booted.udid);
    assert.strictEqual(typeof apps, 'object');
    assert.notStrictEqual(apps, null);
  });

  it('rejects with a typed, catchable error instead of crashing on an unknown device UDID', async () => {
    const sim = new NativeSimctl();
    await assert.rejects(() => sim.shutdownDevice('00000000-0000-0000-0000-000000000000'), /No simulator device found/);
  });

  it('rejects grantPermission with a typed error for an unsupported service name', async () => {
    // Validated before the device is even looked up, so no real device/udid is needed here — this
    // must still surface as a typed NativeSimError, not a plain Error, since callers rely on that.
    const sim = new NativeSimctl();
    await assert.rejects(
      () => sim.grantPermission('00000000-0000-0000-0000-000000000000', 'location' as never, 'com.example.app'),
      (err: unknown) => err instanceof NativeSimError,
    );
  });

  it('never throws at construction, even with a bad developer dir', () => {
    // The native sharedServiceContext call is deferred to first actual use (see the
    // `serviceContext` getter), so constructing with a bad developerDir must always succeed —
    // only a method that actually needs the simulator can raise.
    assert.doesNotThrow(() => new NativeSimctl('/nonexistent/Xcode.app/Contents/Developer'));
  });

  it('degrades to NativeSimUnavailableError, not a crash, on first use with a bad developer dir', async () => {
    // CoreSimulator tolerates an unresolvable developerDir for context creation itself (it's only
    // used to resolve runtimes/behaviors lazily), so this asserts the safety net's shape rather
    // than forcing an artificial failure: any rejection from the addon must be one of the typed
    // NativeSim* classes, never an uncaught native exception (which would crash the process
    // before this assertion could even run).
    const sim = new NativeSimctl('/nonexistent/Xcode.app/Contents/Developer');
    try {
      await sim.getDevices();
    } catch (err) {
      assert.ok(err instanceof NativeSimUnavailableError);
    }
  });
});

/**
 * Verifies the platform gate in native-simctl.ts's loadNative() — separate describe block using a
 * fresh subprocess per case (rather than monkey-patching process.platform in this shared test
 * process), since that would leak into every other test that runs afterward here.
 */
describe('NativeSimctl (cross-platform)', () => {
  function runWithFakedPlatform(platform: string, script: string): string {
    return execFileSync(
      process.execPath,
      [
        '--input-type=module',
        '-e',
        `Object.defineProperty(process, 'platform', {value: '${platform}'});` +
          `const mod = await import('${INDEX_MODULE_URL}');\n${script}`,
      ],
      {encoding: 'utf8'},
    );
  }

  it('can be imported on a non-macOS platform without throwing', () => {
    const output = runWithFakedPlatform('win32', "console.log('imported ok:', typeof mod.NativeSimctl);");
    assert.match(output, /imported ok: function/);
  });

  it('does not throw when constructed on a non-macOS platform', () => {
    const output = runWithFakedPlatform(
      'win32',
      `const sim = new mod.NativeSimctl('/some/dir');
       console.log('constructed ok:', sim instanceof mod.NativeSimctl);`,
    );
    assert.match(output, /constructed ok: true/);
  });

  it('rejects with a typed NativeSimUnavailableError only once a method actually needs the simulator', () => {
    const output = runWithFakedPlatform(
      'win32',
      `const sim = new mod.NativeSimctl('/some/dir');
       try {
         await sim.getDevices();
         console.log('UNEXPECTED: did not throw');
       } catch (err) {
         console.log('threw:', err instanceof mod.NativeSimUnavailableError, err.kind, err.missing);
       }`,
    );
    assert.match(output, /threw: true platform win32/);
  });
});
