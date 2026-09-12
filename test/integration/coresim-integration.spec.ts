import assert from 'node:assert';
import {execFileSync} from 'node:child_process';
import {once} from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {after, before, describe, it} from 'node:test';

import {waitForCondition} from 'asyncbox';

import {NativeSimctl, SimDeviceState, type SimDeviceInfo} from '../../src/index.js';
import {getUIKitCatalogPath, UICATALOG_BUNDLE_ID} from '../fixtures.js';

// GitHub Actions sets this for every job; real simulator boot on a CI runner is dramatically
// slower than on real hardware (appium-ios-simulator's own e2e suite doubles an already-8-minute
// local boot budget to 16 minutes for CI: test/functional/helpers.ts's LONG_TIMEOUT). On this
// machine the native async boot path completes in well under a second.
const IS_CI = Boolean(process.env.CI);

/**
 * `deleteDevice:error:` returns success synchronously but the actual removal (filesystem cleanup)
 * happens on a background queue — empirically confirmed to settle within ~500ms, but polled with
 * headroom here rather than assuming a fixed delay.
 */
async function waitUntilDeleted(sim: NativeSimctl, udid: string): Promise<void> {
  await waitForCondition(async () => !(await sim.getDevices()).some((d) => d.udid === udid), {
    waitMs: 5000,
    intervalMs: 250,
    error: 'expected the throwaway device to disappear',
  });
}

/** A throwaway self-signed cert for addCertificate/addRootCertificate — content doesn't matter. */
function createSelfSignedCert(): string {
  const certPath = path.join(os.tmpdir(), `coresim-test-cert-${Date.now()}-${process.pid}.pem`);
  execFileSync('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-keyout',
    '/dev/null',
    '-out',
    certPath,
    '-days',
    '1',
    '-nodes',
    '-subj',
    '/CN=coresim-test',
  ]);
  return certPath;
}

/** iOS-only checks (app install, openUrl) need a real browser/app-install surface tvOS/watchOS/visionOS don't have. */
function isIOSRuntime(runtimeIdentifier: string): boolean {
  return runtimeIdentifier.includes('.SimRuntime.iOS-');
}

interface RuntimeFixture {
  runtimeIdentifier: string;
  runtimeName: string;
  deviceTypeIdentifier: string;
}

/**
 * One (runtime, compatible device type) pair per distinct simulator runtime actually installed —
 * borrowed from an existing device rather than guessed out of supportedDeviceTypes() (which
 * includes watchOS/tvOS/visionOS types that aren't compatible with an iOS runtime), so
 * createDevice is guaranteed to succeed against every entry this returns.
 */
async function availableRuntimeFixtures(sim: NativeSimctl): Promise<RuntimeFixture[]> {
  const [runtimes, devices] = await Promise.all([sim.getSupportedRuntimes(), sim.getDevices()]);
  const runtimeNameById = new Map(runtimes.map((r) => [r.identifier, r.name]));
  const deviceTypeByRuntime = new Map<string, string>();
  for (const device of devices) {
    if (device.runtimeIdentifier && device.deviceTypeIdentifier && !deviceTypeByRuntime.has(device.runtimeIdentifier)) {
      deviceTypeByRuntime.set(device.runtimeIdentifier, device.deviceTypeIdentifier);
    }
  }
  return [...deviceTypeByRuntime.entries()].map(([runtimeIdentifier, deviceTypeIdentifier]) => ({
    runtimeIdentifier,
    runtimeName: runtimeNameById.get(runtimeIdentifier) ?? runtimeIdentifier,
    deviceTypeIdentifier,
  }));
}

// Resolved via top-level await (before any describe/it registers) since node:test builds its test
// tree synchronously — the per-runtime describe blocks below need the fixture list up front.
const sim = new NativeSimctl();
const fixtures = await availableRuntimeFixtures(sim);
const targets = IS_CI ? fixtures : fixtures.slice(0, 1);
// One throwaway cert shared across every runtime's keychain checks — its content is irrelevant,
// so there's no reason to mint a fresh one per runtime.
const certPath = createSelfSignedCert();

/**
 * Mutating coverage against the real CoreSimulator device set, run per simulator runtime — the
 * "simulator version" axis of the matrix the CI job matrix (integration-test.yml, which selects a
 * different Xcode/CoreSimulator version per job via maxim-lobanov/setup-xcode) doesn't cover on
 * its own: a single Xcode install can ship more than one simulator runtime (this dev machine has
 * two). Each runtime gets its own throwaway device, created/booted once and shared by every check
 * against it — never a developer's pre-existing simulators. Read-only checks live under
 * test/unit instead.
 *
 * Locally, only the first available runtime is exercised (fast dev loop, regardless of how many
 * old runtimes happen to accumulate on a real machine over time); in CI, every runtime the job's
 * Xcode has installed is exercised, since that set is small and controlled per runner image.
 */
describe('NativeSimctl integration', () => {
  if (targets.length === 0) {
    it('skips: no simulator runtime with an installed device type is available', () => {});
  }

  after(async () => {
    await fs.promises.rm(certPath, {force: true});
  });

  for (const fixture of targets) {
    describe(`runtime ${fixture.runtimeName} (${fixture.runtimeIdentifier})`, () => {
      let device: SimDeviceInfo | undefined;

      before(async () => {
        device = await sim.createDevice(
          `coresim-test-${Date.now()}`,
          fixture.deviceTypeIdentifier,
          fixture.runtimeIdentifier,
        );
        // createDevice's own async work always resolves the device out of the transient Creating
        // state before the promise settles.
        assert.strictEqual(device.state, SimDeviceState.Shutdown);
        await sim.bootDevice(device.udid);
        // SimDeviceState reaching Booted only means the OS kernel/launchd has started — data
        // migration and system-app (SpringBoard) startup can still take tens of seconds longer
        // (see CLAUDE.md), and unlike getEnv() (a plain host-filesystem read), not every endpoint
        // is necessarily as graceful about running against a not-yet-fully-settled simulator.
        // Waiting here, once, up front means every check below runs against a genuinely booted
        // device instead of each one having to reason about this itself.
        await sim.waitForBoot(device.udid);
      });

      after(async () => {
        if (!device) {
          return;
        }
        // The eraseDevice test (last, below) leaves the device already Shutdown — shutdownDevice()
        // on an already-Shutdown device rejects ("Unable to shutdown device in current state:
        // Shutdown") rather than being a no-op, confirmed empirically — so only call it if needed,
        // never rebooting the device just to re-shut it down.
        const current = (await sim.getDevices()).find((d) => d.udid === device!.udid);
        if (current?.state === SimDeviceState.Booted) {
          await sim.shutdownDevice(device.udid);
        }
        await sim.deleteDevice(device.udid);
        await waitUntilDeleted(sim, device.udid);
      });

      it('boots via the async native path', async () => {
        // No polling needed here: the before() hook's waitForBoot() already requires state to be
        // Booting/Booted at entry and only returns once boot has fully settled, and state has
        // never been observed to regress back out of Booted while that settling happens.
        const found = (await sim.getDevices()).find((d) => d.udid === device!.udid);
        assert.strictEqual(found?.state, SimDeviceState.Booted);
      });

      it('reads getenv from the booted device', async () => {
        const home = await sim.getEnv(device!.udid, 'HOME');
        assert.match(home, /CoreSimulator\/Devices/);
      });

      it('configures the booted device (location, Darwin notification)', async () => {
        await sim.setLocation(device!.udid, 37.7749, -122.4194);
        await sim.postDarwinNotification(device!.udid, 'com.appium.coresim.test');
      });

      it('gets and sets Darwin notification state', async () => {
        const name = 'com.appium.coresim.test.state';
        assert.strictEqual(await sim.getDarwinNotificationState(device!.udid, name), 0);
        await sim.setDarwinNotificationState(device!.udid, name, 1);
        assert.strictEqual(await sim.getDarwinNotificationState(device!.udid, name), 1);
      });

      it('gets and sets UI appearance, increase contrast, and content size', async () => {
        await sim.getAppearance(device!.udid);
        await sim.setAppearance(device!.udid, 2);
        assert.strictEqual(await sim.getAppearance(device!.udid), 2);

        await sim.getIncreaseContrast(device!.udid);
        await sim.setIncreaseContrast(device!.udid, false);

        await sim.getContentSize(device!.udid);
        await sim.setContentSize(device!.udid, 3);
        assert.strictEqual(await sim.getContentSize(device!.udid), 3);
      });

      it('adds a certificate to the keychain (path and Buffer, as trusted root) and resets it', async () => {
        await sim.addCertificate(device!.udid, certPath);
        await sim.addRootCertificate(device!.udid, await fs.promises.readFile(certPath));
        await sim.resetKeychain(device!.udid);
      });

      it('delivers a simulated push notification', async () => {
        // Confirmed to work regardless of whether the target bundle is actually installed.
        await sim.pushNotification(device!.udid, 'com.appium.coresim.doesnotexist', {aps: {alert: 'hi'}});
      });

      it('rejects grantPermission/revokePermission/resetPermission with a typed error', async () => {
        // Confirmed empirically: these fail with NSPOSIXErrorDomain/EPERM even with a real
        // installed bundle and a valid permission name, while the exact same operation succeeds
        // via the signed `simctl` CLI on this same machine — a TCC/entitlement check tied to the
        // *calling process*'s code signature, not something this addon's own code can fix (see
        // CLAUDE.md). This asserts the plumbing still surfaces a clean, catchable, typed error
        // instead of crashing — not that the grant actually takes effect.
        const bundleId = 'com.appium.coresim.doesnotexist';
        await assert.rejects(() => sim.grantPermission(device!.udid, 'location', bundleId), /NativeSimOperationError/);
        await assert.rejects(() => sim.revokePermission(device!.udid, 'location', bundleId), /NativeSimOperationError/);
        await assert.rejects(() => sim.resetPermission(device!.udid, 'location', bundleId), /NativeSimOperationError/);
      });

      if (isIOSRuntime(fixture.runtimeIdentifier)) {
        it('opens a URL', async () => {
          await sim.openUrl(device!.udid, 'https://appium.io');
        });

        it('installs, inspects, launches, terminates, and removes an app', async () => {
          const appPath = await getUIKitCatalogPath();
          await sim.installApp(device!.udid, appPath);
          assert.ok(await sim.isAppInstalled(device!.udid, UICATALOG_BUNDLE_ID));

          const info = await sim.appInfo(device!.udid, UICATALOG_BUNDLE_ID);
          assert.strictEqual(info.CFBundleIdentifier, UICATALOG_BUNDLE_ID);
          assert.ok(UICATALOG_BUNDLE_ID in (await sim.installedApps(device!.udid)));

          const pid = await sim.launchApp(device!.udid, UICATALOG_BUNDLE_ID);
          assert.ok(pid > 0);
          await sim.terminateApp(device!.udid, UICATALOG_BUNDLE_ID);

          await sim.removeApp(device!.udid, UICATALOG_BUNDLE_ID);
          assert.strictEqual(await sim.isAppInstalled(device!.udid, UICATALOG_BUNDLE_ID), false);
        });
      }

      it('spawns a process with live stdout and reports a clean exit', async () => {
        const proc = await sim.spawnProcess(device!.udid, '/bin/echo', {
          arguments: ['/bin/echo', 'hello-from-integration-test'],
        });
        assert.ok(proc.running);
        let stdout = '';
        proc.stdout.on('data', (chunk) => {
          stdout += chunk;
        });
        // 'exit' (fired via the native ThreadSafeFunction/GCD termination handler) and the stdout
        // stream's own 'end' (driven independently by libuv polling the dup()'d fd) are decoupled
        // signals — 'exit' can fire before the stream has finished (or even started) delivering
        // its buffered data (observed in CI: stdout was still '' when 'exit' had already fired).
        // Wait for both before asserting on accumulated output.
        const [[code, signal]] = await Promise.all([once(proc, 'exit'), once(proc.stdout, 'end')]);
        assert.strictEqual(code, 0);
        assert.strictEqual(signal, null);
        assert.strictEqual(proc.running, false);
        assert.match(stdout, /hello-from-integration-test/);
      });

      it('kills a long-running spawned process', async () => {
        const proc = await sim.spawnProcess(device!.udid, '/bin/sleep', {arguments: ['/bin/sleep', '30']});
        assert.ok(proc.running);
        const exitPromise = once(proc, 'exit');
        assert.ok(proc.kill());
        const [code, signal] = await exitPromise;
        assert.strictEqual(code, null);
        assert.strictEqual(signal, 'SIGTERM');
      });

      it('reports settled boot status, and a further waitForBoot call is immediate', async () => {
        // The before() hook already waited for full settlement, so both checks here should be
        // near-instant — this exercises the "already booted" fast path specifically.
        const status = await sim.getBootStatus(device!.udid);
        assert.strictEqual(status?.isTerminal, true);

        const start = Date.now();
        await sim.waitForBoot(device!.udid);
        assert.ok(Date.now() - start < 2000, 'expected waitForBoot to return near-instantly once already settled');
      });

      it('rejects waitForBoot for a device that is not booting or booted', async () => {
        // A fresh device is Shutdown and was never booted — cheap to create (no boot involved),
        // so this doesn't need the shared per-runtime device or a second real boot.
        const fresh = await sim.createDevice(
          `coresim-test-notrunning-${Date.now()}`,
          fixture.deviceTypeIdentifier,
          fixture.runtimeIdentifier,
        );
        try {
          assert.strictEqual(await sim.getBootStatus(fresh.udid), null);
          await assert.rejects(() => sim.waitForBoot(fresh.udid));
        } finally {
          await sim.deleteDevice(fresh.udid);
        }
      });

      // Last: eraseDevice requires Shutdown (see CLAUDE.md), and leaves the device that way — no
      // later test here can assume Booted again. The outer after() hook tolerates this without
      // rebooting the device just to shut it down a second time.
      it('erases the device once shut down', async () => {
        await sim.shutdownDevice(device!.udid);
        await sim.eraseDevice(device!.udid);
        assert.strictEqual(
          (await sim.getDevices()).find((d) => d.udid === device!.udid)?.state,
          SimDeviceState.Shutdown,
        );
      });
    });
  }
});
