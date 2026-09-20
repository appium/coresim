# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
npm install                      # installs deps; compiles the native addon via node-gyp-build if no prebuild exists
npm run build                    # TypeScript compile
npm run build:addon              # rebuild the native addon from source (node-gyp)
npm run build:addon:xcodebuild   # rebuild via xcodebuild with -Wall -Wextra -Werror (needs full Xcode, not just CLTs)
npm run build:prebuilds          # produce N-API prebuilds under prebuilds/

npm run lint / lint:fix          # oxlint for TS/JS
npm run format:cpp / lint:cpp    # clang-format / clang-tidy for the native code (not installed by npm install)

npm test                         # unit + integration
npm run test:unit                # no simulator required
npm run test:integration         # needs a real simulator
```

## Project structure

```
src/
  coresim.mm       # N-API glue: NativeDevice/NativeDeviceSet/NativeServiceContext ObjectWrap classes
  native/          # Objective-C++ helpers: dynamic ObjC dispatch, exception safety, async bridging,
                    # error conversion, JS<->NSObject value conversion, and a TCC.db (privacy) accessor
  native-simctl.ts # NativeSimctl core (construction, service-context/device lookup)
  commands/        # NativeSimctl's public methods, grouped by topic, mixed into the class
  utils/           # small dependency-free helpers shared by native-simctl.ts and commands/*.ts
  types.ts         # public types + internal shapes describing the native addon's exports
  errors.ts        # typed error classes + mapping from raw addon errors
  index.ts         # package entry

test/
  unit/            # no simulator required
  integration/     # exercises real devices; one throwaway device per simulator runtime

scripts/install.mjs # install-time no-op off macOS, so `npm install` never fails on other platforms
```

## Architecture

This is a Node.js native addon that binds `CoreSimulator.framework` directly — the same private
framework `simctl` and Xcode are themselves built on — instead of shelling out to the `simctl` CLI.
Native functionality is macOS-only; the package itself installs anywhere (no `os`/`cpu` restriction),
and any method that actually needs the simulator throws a typed `NativeSimUnavailableError` on other
platforms instead of attempting to load a nonexistent addon.

**Dynamic dispatch, not headers.** `CoreSimulator.framework` ships no public headers, so every class
and selector is resolved at runtime (`NSClassFromString`/`respondsToSelector:`) rather than linked
statically, and every call is exception-guarded (`@try`/`@catch` around each dispatch) so a missing
selector or a native exception surfaces as a catchable, typed JS error instead of crashing the
process. This is the load-bearing safety net for the whole addon — any new native call must go
through it.

**Native layer** (`src/coresim.mm`, `src/native/`): an ARC-enabled Objective-C++ N-API addon. Every
method that can trigger a CoreSimulator dispatch runs off the main thread and resolves/rejects a
Promise, so a slow operation never blocks Node's event loop. `spawnProcess` is the one exception to
the simple one-shot-resolve pattern, since a spawned process's exit can arrive long after the initial
promise (carrying the pid) already resolved.

**TypeScript layer** (`src/`): `NativeSimctl`'s public method surface lives in `src/commands/*.ts`,
grouped by topic and mixed into the class (mirroring `@appium/base-driver`'s command-mixin pattern)
rather than defined directly on the class body. Devices are addressed by UDID; every method
re-resolves the native device handle from the live device set rather than caching it, so a device
deleted elsewhere surfaces as a normal "not found" error. The public surface intentionally mirrors
`node-simctl`'s own `Simctl` API shape, plus a few additions (`getBootStatus`/`waitForBoot`, a
streaming `spawnProcess`) that only make sense once you're not just wrapping a CLI.

**Tests and CI**: unit tests cover everything read-only; integration tests cover the mutating device
lifecycle against one throwaway device on a real simulator, validated in CI across a matrix of
Xcode/CoreSimulator versions (a different Xcode ships a different CoreSimulator build — the axis
that actually matters here). The native addon build treats compiler warnings as errors on every
toolchain (`make` and `xcodebuild`).

## Things worth knowing before changing native code

- **CoreSimulator's own state transitions are eventually consistent.** A `deleteDevice`/`boot` call
  can resolve before `devices()` reflects the new state — code that needs to observe a transition
  should poll for it rather than assume it's immediate.
- **`SimDeviceState` reaching `Booted` is not the same as "the simulator is actually ready".** It only
  means the OS kernel has started; data migration and system-app startup can take much longer. Use
  `getBootStatus()`/`waitForBoot()` (a separate, more granular signal — the same one `simctl
  bootstatus` itself polls) when a check needs a genuinely settled simulator.
- **A wrong-shaped argument to some native calls crashes the whole process, not just the call.**
  Exceptions raised on a thread other than the one that made the call can't be caught by the usual
  `@try`/`@catch` guard. `spawnProcess`'s `stdout`/`stderr` handling is the known instance of this —
  it's why the addon always manages those pipes itself rather than accepting them as options. Also
  confirmed the hard way: passing the pipe's `NSFileHandle` object itself (not just a wrong type)
  crashed the process on some CoreSimulator versions via `-[NSConcreteFileHandle intValue]:
  unrecognized selector` — the internal handler wants a raw fd number (`NSNumber`).
- **`spawnProcess`'s `path` is always resolved against the Simulator's own runtime root and
  confined there** (`ResolveRuntimeBinaryPath` in coresim.mm) — it cannot be used to spawn an
  arbitrary host executable. A leading `/` is tolerated (still joined under the runtime root, not
  the host's own `/`); a `path` that would resolve outside it (e.g. via `..`) throws, checked via
  `-stringByStandardizingPath` rather than a naive string search. Deliberately breaking: earlier
  versions took `path` as a literal, unconfined path.
- **A bare `path` (no `/`) is resolved by searching a fixed list of standard bin dirs under the
  runtime root** (`ResolveBareCommand` in coresim.mm: `usr/bin`, `bin`, `usr/sbin`, `sbin`,
  `usr/local/bin`), mirroring `simctl spawn`'s own bare-name resolution. This is a guess, not a
  real `$PATH` search — there's no way to read the guest's actual `$PATH` before a process exists
  to read it from — so a binary outside those dirs must still be spawned by its full path.
- **`spawnProcess` always sets the spawn options' `"standalone"` key to `false`**
  (`kSimDeviceSpawnStandalone`, confirmed via `strings` on the framework binary — no public header
  exists), not caller-configurable — since `path` always resolves inside the guest runtime
  (above), every spawn needs to stay attached to the guest's launchd bootstrap namespace to
  function / have its effects observed there. Known risk accepted deliberately: some CoreSimulator
  versions (Xcode 26.4+) instead require a *standalone* spawn for a non-system binary to load its
  dyld shared cache correctly, aborting a non-standalone one with SIGABRT trying to load even
  `libSystem.B.dylib` — reproduced only on hosted CI (never locally), diagnosed from the child's
  own crash report, and only previously worked around (not root-caused) by defaulting to
  standalone. If this resurfaces for a runtime binary, it needs a real fix here, not a caller
  escape hatch.
- **Privacy permissions (`grantPermission`/`revokePermission`/`resetPermission`) are implemented by
  writing directly to the simulator's own TCC (privacy) SQLite database**, not by calling
  CoreSimulator's private privacy API — that API requires a process entitlement no ordinary npm
  package can obtain. `location` isn't supported this way since it isn't a plain TCC row.
- **Several CoreSimulator operations reject if the device isn't in the exact state they expect**
  (e.g. erasing requires `Shutdown`; shutting down an already-`Shutdown` device also rejects) rather
  than being idempotent no-ops — callers need to check state first.
- **Pasteboard sync (`getPasteboard`/`setPasteboard`) needs no special entitlement** — see
  `sim_pasteboard.mm` for the two private mechanisms it picks between and how.
- **Screenshot capture (`getScreenshot`) reads the device's live framebuffer `IOSurface` in-process**
  — no entitlement, no temp file, no `simctl` subprocess — see `sim_screenshot.mm` for how the main
  display's IO port is found and rendered to PNG.
- **Video recording (`startVideoRecording`/`stopVideoRecording`) drives a private CoreSimulator API
  directly, reverse-engineered via `strings` on the real `simctl` binary — no public header exists.**
  The receiver isn't the renderable display descriptor `getScreenshot` reads
  (`sim_screenshot.mm`'s `ResolveCaptureDisplay`, which that descriptor is still passed as the
  `screen` *argument*) — it's a separate, device-wide "capture service" descriptor found by
  scanning `-[device io] ioPorts` for whichever one responds to
  `startRecordingFromScreen:maskPolicy:assetWriterOutputSettings:outputFile:completionQueue:completionHandler:`
  (see `sim_video_recording.mm`'s `ResolveVideoCaptureService`). Confirmed empirically (real
  recordings, `ffprobe`-validated against real `xcrun simctl io recordVideo` output): `outputFile`
  must be an `NSString*` absolute path — an `NSURL*` reliably hangs the completion handler forever
  instead of erroring; an empty `assetWriterOutputSettings` records H.264 (CoreSimulator's own
  default, distinct from `simctl`'s CLI-level HEVC default — `simctl` just always passes the
  codec key); `maskPolicy` `0`/`1`/`2` map to ignored/alpha/black, with alpha indistinguishable
  from black in the actual captured pixels (matches `simctl`'s own `--mask` help text). Calling
  `stopRecordingWithCompletionQueue:completionHandler:` before `startRecordingFromScreen:...`'s own
  completion handler has fired is a real, silent race — no crash, but `stop` reports
  `NSPOSIXErrorDomain(22)` ("No recording in progress") while `start` separately reports success,
  net effect an empty file — this is why `commands/video-recording.ts` tracks one active recording
  per device and this addon's async methods only ever resolve `start` after CoreSimulator's own
  completion handler (not just the call) has fired, so an `await start(); await stop();` sequence
  in JS can never hit this race.
- **Video streaming (`startVideoStream`) is a completely different mechanism from video
  recording — it uses no private API at all.** `startRecordingFromScreen:...` only ever writes to
  a file with no per-frame callback, so live access units aren't obtainable from it. Instead,
  `sim_video_stream.mm` polls the same renderable display `IOSurface` `getScreenshot` reads
  (`ResolveCaptureDisplay`/`CurrentDisplaySurface`, both exposed from `sim_screenshot.h` for this)
  on a GCD timer, skips a tick when `IOSurfaceGetSeed()` hasn't changed (mirroring
  `startVideoRecording`'s own "only encode on change" behavior), and feeds changed frames through
  a real `VTCompressionSession` (public VideoToolbox API) to produce actual H.264/HEVC access
  units — Annex-B framed, keyframes with parameter sets (SPS/PPS, or VPS/SPS/PPS for HEVC)
  prepended so every keyframe is self-decodable alone. Verified empirically:
  `ffmpeg`/`ffprobe`-decoded output for both codecs, and 8 rapid start/stop cycles (including
  stopping within 5ms of starting) with zero crashes and a clean process exit afterward (no leaked
  `Napi::ThreadSafeFunction` keeping the event loop alive). The tricky part was teardown ordering:
  `VideoStreamSession::Stop()` (external callers) must `dispatch_sync` onto the encoder's own
  serial queue to guarantee no `Tick()` is still in flight before tearing down, but the *same*
  teardown triggered internally, from inside a failing `Tick()` itself, must skip that
  `dispatch_sync` (already executing serially on that queue — `dispatch_sync`ing onto your own
  currently-running queue deadlocks) — see `Impl::Stop()` vs. `Impl::StopFromQueue()`. An `onEnd`
  callback (fired exactly once, from whichever teardown path wins a race between the two) is the
  only reliable point to release the N-API `ThreadSafeFunction`s — neither `onAccessUnit` nor
  `onError` has a "this was the last call" signal of its own. Independent of `startVideoRecording`
  entirely: both can run concurrently on the same device, and multiple concurrent streams are
  allowed (no `commands/video-recording.ts`-style one-per-device tracking here). API shape
  (`start()`/`accessUnits()` async generator/`stop()`) deliberately mirrors
  `appium-ios-remotexpc`'s `ScreenStreamCapture` for consistency — but nothing about the transport
  is shared; that reads an RTP feed from real device hardware over a RemoteXPC tunnel, this is
  pure in-process `IOSurface` polling with no real-device analog at all.
- **A `VideoStream` can never actually be garbage-collected while its stream is still running —
  not a bug, but worth knowing before "fixing" it.** The `onAccessUnit`/`onError` JS callbacks
  passed into `startVideoStream` close over the `VideoStream` instance itself; a live
  `Napi::ThreadSafeFunction` holds a strong/persistent V8 reference to that callback until
  `.Release()`d (only from `stop()`/`onEnd`), which roots the whole closure chain — so an
  abandoned, never-`stop()`'d stream can't be collected, and its encoder (and the Node process,
  since a live `ThreadSafeFunction` keeps the event loop alive) just keeps running forever. This
  is the same "explicit cleanup required" contract every other live resource in this addon has
  (a spawned process, an open pasteboard sync, etc.) — confirmed empirically (a deliberately
  abandoned stream plus two forced `global.gc()` passes never let the process exit). `coresim.mm`'s
  `NativeVideoStream::Finalize` override (hands teardown off to a background queue instead of
  blocking synchronously during GC, unlike the default `ObjectWrap` finalizer) is still correct
  defense-in-depth, but by the above is actually unreachable until *after* an explicit `stop()`
  has already run and broken the cycle — at which point it's a harmless no-op (`Stop()` is
  idempotent).
- **`getAppContainer` is a pure TS convenience wrapper over `appInfo`'s existing `Path`/
  `DataContainer`/`GroupContainers` fields** (see `commands/app.ts`) — no new native call, since
  `propertiesOfApplication:` already reports every container path `simctl get_app_container` does.
- **Biometric enrollment/matching (`enrollBiometric`/`sendBiometricMatch`/`isBiometricEnrolled`) and
  `shake` are pure TS wrappers over the existing Darwin notification primitives** (see
  `commands/biometric.ts`/`commands/misc.ts`) — the same mechanism Simulator.app's own Features menu
  drives, so no new native code was needed for them.
- **`getWebInspectorSocket` has no CoreSimulator dispatch at all** — `SimDevice`/`SimDeviceSet`
  expose no PID/socket accessor for a device's own `launchd_sim`. Instead it's `libproc`/`sysctl`
  process introspection (see `native/sim_process.mm`), the same mechanism `lsof -aUc launchd_sim`
  uses: match the target UDID against `launchd_sim`'s argv, then scan its fds for a Unix socket
  ending in `com.apple.webinspectord_sim.socket`. Returns just the path; no entitlement needed.
- **A non-default device set (`simctl --set <path>`'s equivalent) is opt-in per `NativeSimctl`
  instance** — pass `deviceSetPath` as the constructor's second argument; every device lookup then
  resolves against `-[SimServiceContext deviceSetWithPath:error:]` instead of
  `defaultDeviceSetWithError:`. Unset, behavior is unchanged (the default device set).
- **`listProcesses` must spawn the guest runtime's own `launchctl`, not the host's
  `/bin/launchctl`** — the host binary exits 5 (wrong launchd). It spawns it by bare name
  (`spawnProcess`'s own PATH-like resolution, above, finds it under the runtime root), the same
  way `simctl spawn` would resolve it against the guest's `$PATH`. The runtime root itself is also
  exposed publicly as `getRuntimeRootPath`, for callers that need the raw path directly.

## Known gaps

- No handling of a CoreSimulator/Xcode version mismatch requiring an upgrade (the way `simctl`'s own
  wrapper does).
- `spawnProcess` has no writable `stdin`.
