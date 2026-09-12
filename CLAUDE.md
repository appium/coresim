# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
# Install dependencies (also runs node-gyp-build, which compiles the addon if no prebuild exists)
npm install

# TypeScript compile (runs on prepare after install; required before tests if lib/ is stale)
npm run prepare

# Build only the native C++/Objective-C++ addon (from source)
npm run build:addon

# Produce N-API prebuilds under prebuilds/ (release CI uses this)
npm run build:prebuilds

# Build only TypeScript
npm run build

# Lint (TypeScript/JS via oxlint)
npm run lint
npm run lint:fix

# Format/lint Objective-C++ (clang-format/clang-tidy; not installed by `npm install`)
npm run format:cpp
npm run format:cpp:check
npm run lint:cpp

# Rebuild the native addon via xcodebuild with -Wall -Wextra -Werror (warnings fail the build);
# requires Xcode, not just the CLTs (needs `node-gyp configure -- -f xcode`)
npm run build:addon:xcodebuild

# Tests (unit + integration; integration needs a real simulator)
npm test
npm run test:unit
npm run test:integration

# Simulate CI's shared-device test behavior locally (see Tests section below)
CI=true npm run test:integration
```

## Project structure

```
src/
  coresim.mm                    # N-API glue: NativeDevice/NativeDeviceSet/NativeServiceContext
                                 # ObjectWrap classes + module init. No dynamic dispatch of its
                                 # own — only JS<->ObjC value translation and error reporting.
  native/
    objc_runtime.h/.mm          # dlopen(CoreSimulator), NSClassFromString/respondsToSelector
                                 # guards, NativeSimUnavailableError, framework version
    safe_dispatch.h             # SafeInvoke<Fn> — @try/@catch around every objc_msgSend call,
                                 # converts NSException -> ObjCException (never crashes)
    async_bridge.h              # RunAsync<T>/RunAsyncVoid — runs work on a libuv threadpool
                                 # thread, resolves/rejects a Promise; what makes every
                                 # CoreSimulator-dispatching method async
    nserror_bridge.h/.mm        # NSError(Exception)/NativeSimUnavailableError/ObjCException ->
                                 # JS Error
    value_bridge.h/.mm          # JS value <-> NSObject (options dicts, propertiesOfApplication)
    sim_service_context.mm      # SimServiceContext + SimDeviceType/SimRuntime accessors
    sim_device_set.mm           # SimDeviceSet: devices/createDevice/deleteDevice
    sim_device.mm               # SimDevice: the full lifecycle/app/permission/spawn surface
  errors.ts                     # NativeSimError + typed subclasses, wrapNativeError()
  types.ts                      # Public SimDevice*/SimRuntime*/SpawnOptions types + internal
                                 # Native*Handle shapes for the addon's exports (see coresim.mm)
  native-simctl.ts              # NativeSimctl core: constructor, frameworkVersion,
                                 # _serviceContext/_deviceSet/_findDevice — mixes in commands/*.ts
  commands/                     # NativeSimctl's public method surface, grouped by topic and mixed
                                 # into the class via Object.assign(NativeSimctl.prototype, ...)
                                 # (mirrors @appium/base-driver's basedriver/commands/ pattern)
    lifecycle.ts                 # getDevices/getSupportedDeviceTypes/getSupportedRuntimes/
                                  # createDevice/deleteDevice/bootDevice/getBootStatus/waitForBoot/
                                  # shutdownDevice/eraseDevice
    app.ts                        # installApp/removeApp/launchApp/terminateApp/isAppInstalled/
                                  # appInfo/installedApps
    interaction.ts                # getEnv/openUrl/setLocation/pushNotification
    keychain.ts                   # addCertificate/addRootCertificate/resetKeychain
    ui.ts                         # get/setAppearance, get/setIncreaseContrast, get/setContentSize
    permissions.ts                # grantPermission/revokePermission/resetPermission
    darwin-notification.ts        # get/setDarwinNotificationState, postDarwinNotification
    spawn.ts                      # spawnProcess + SpawnedProcess (live stdout/stderr + exit handle)
  utils/                        # Shared, dependency-free helpers — a barrel (index.ts re-exports
                                 # each file), imported by native-simctl.ts and every commands/*.ts
                                 # mixin, never the other way around
    pkg-root.ts                   # Memoized package root for node-gyp-build (PACKAGE_NAME too)
    run-catching.ts                # runCatchingAsync() — maps a raw addon error to a typed one
    index.ts                       # Barrel: re-exports pkg-root.ts and run-catching.ts
  index.ts                      # Package entry

test/
  unit/        # node:test specs, no simulator required
  integration/ # node:test specs against a real booted simulator

scripts/
  install.mjs  # "install" lifecycle script — skips the native build off darwin so
               # `npm install` never fails there; see Architecture below
```

## Architecture

This is a Node.js native addon that binds `CoreSimulator.framework` directly — the private,
unsigned-but-unrestricted framework `simctl`/Xcode are themselves built on —
instead of shelling out to the `simctl` CLI. **Native functionality is macOS only**: the framework
doesn't exist anywhere else. The package **installs on any platform/arch** — `package.json`
deliberately has no `"os"`/`"cpu"` restriction, and `scripts/install.mjs` (the `"install"`
lifecycle script) checks `process.platform` itself and skips straight to a no-op everywhere except
darwin, so `npm install` never fails elsewhere. `native-simctl.ts`'s `loadNative()` mirrors that
check at runtime — not at module-import time (importing `@appium/coresim` for its error
classes/types works anywhere), and not at `new NativeSimctl()` construction time either: the
native `sharedServiceContext` call (and the platform check gating it) is deferred to the
private `serviceContext` getter, memoized on first access, so only a method that actually needs
the simulator (`getDevices()`, `createDevice()`, ...) can throw — `NativeSimctl.frameworkVersion()`
calls `loadNative()` directly since it needs the addon but not a service context. Either path
throws a typed `NativeSimUnavailableError` (`kind: 'platform'`) instead of attempting to load a
nonexistent addon. Neither check restricts `arch`: an Intel Mac (`darwin`/`x64`) is expected to
compile the addon from source via `node-gyp` (Objective-C++ compiles fine there too) since
`prebuilds/` only ships a `darwin-arm64` binary
today (`binding.gyp` itself has no per-arch conditionals either — same single target either way).

### Why dynamic dispatch, not headers

`CoreSimulator.framework` ships no public headers, and its Objective-C surface has zero API
stability guarantee from Apple (in practice it has been stable for a decade — this is what
`simctl` and Xcode already depend on). So **every class and selector is
resolved at runtime, never linked statically**:

1. `RequireClass`/`RequireSelector` (`objc_runtime.mm`) check `NSClassFromString`/
   `respondsToSelector:` before every call and throw `NativeSimUnavailableError` (naming the
   missing class/selector + the loaded framework's `CFBundleVersion`) if either is missing.
2. `SafeInvoke` (`safe_dispatch.h`) wraps every `objc_msgSend` call in `@try`/`@catch` — an
   *uncaught* `NSException` is fatal to the whole Node process, so nothing reaches `objc_msgSend`
   without this guard. A caught exception becomes a C++ `ObjCException`.
3. Both become a catchable JS `Error` (never an uncaught native exception) via `nserror_bridge.h`'s
   `CatchToJs` — `errors.ts`'s `wrapNativeError` turns that back into a typed
   `NativeSimUnavailableError`/`NativeSimDispatchError`/`NativeSimOperationError`.

Real method signatures (selector names + type encodings) were confirmed against the loaded
framework's own Objective-C runtime metadata during development, not guessed — `SimDevice`/
`SimDeviceSet`/`SimServiceContext`'s method counts (272/115/122) match exactly what runtime
introspection reports on this machine's CoreSimulator 1171.6.

### Native layer (`src/coresim.mm`, `src/native/*`)

An Objective-C++ (`.mm`) N-API addon, ARC-enabled (`CLANG_ENABLE_OBJC_ARC=YES` in `binding.gyp`,
so `id` members of C++ classes get automatic retain/release). `coresim.mm` defines three
`Napi::ObjectWrap` classes constructed only internally (via a boxed-`id`
`Napi::External`, never `new SomeClass()` from JS):

- **`NativeServiceContext`** wraps `SimServiceContext`: `defaultDeviceSet()`,
  `supportedDeviceTypes()`, `supportedRuntimes()`.
- **`NativeDeviceSet`** wraps `SimDeviceSet` (plus the owning `SimServiceContext`, needed to
  resolve a device-type/runtime identifier string into the actual `SimDeviceType`/`SimRuntime`
  object `createDeviceWithType:runtime:name:error:` requires): `devices()`, `createDevice()`,
  `deleteDevice()`.
- **`NativeDevice`** wraps `SimDevice`: the full lifecycle/app/permission/spawn method surface.

**Every method that can trigger a CoreSimulator dispatch is async**, via `async_bridge.h`'s
`RunAsync<T>`/`RunAsyncVoid`: each runs a `work` lambda on a libuv threadpool thread
(`Napi::AsyncWorker::Execute`) and resolves/rejects the returned `Napi::Promise` from its result,
converting it to a JS value via a `toValue` callback that runs in `OnOK` (main thread — the only
place Napi calls are safe). This is true regardless of whether the underlying CoreSimulator method
has a real completion-block variant (`boot` uses `bootAsyncWithOptions:completionQueue:
completionHandler:`, blocking on a `dispatch_semaphore_t` inside `work` until the handler fires —
this is what replaces `appium-ios-simulator`'s CLI-era poll-`bootstatus`-until-timeout race with a
deterministic completion signal) or is a plain blocking `NSError**`-returning call
(`shutdownWithError:`, `installApplication:withOptions:error:`, etc., which `work` just calls
directly and converts a failed `BOOL`/`nil` result into a thrown `NSErrorException`): either way,
the blocking happens off the main thread, so a slow install/erase/create/etc. never stalls Node's
event loop. Confirmed empirically, not just by inspection: an `eraseDevice()` call that took 81ms
still let a concurrent 5ms `setInterval` tick 14 times while it was in flight.

`T` can be a plain C++ type (`bool`, `int`, `long long`, `std::string`) or an Objective-C pointer
(`id`, `NSString*`, `NSArray*`, `NSDictionary*`, ...) — the latter works as a plain default-
constructed class member (no `unique_ptr`/`optional` wrapper) purely because this header is only
ever included from an ARC-compiled `.mm` translation unit, same as any other `id`-typed member in
this addon. `toValue` takes `T` **by value**, not `T&` — for an ObjC pointer `T`, a reference
parameter's implicit `__strong` ownership qualifier has to match the callable's declared parameter
type exactly, which a plain lambda parameter doesn't; by-value sidesteps that ARC-qualifier
mismatch entirely (this is a real compile error you'll hit if a new `toValue` callback is written
with a `T&` parameter).

The five trivial in-memory `NativeDevice` property accessors (`udid`/`name`/`state`/
`deviceTypeIdentifier`/`runtimeIdentifier`) are the one deliberate exception, kept synchronous via
the original `CatchToJs` helper: they're plain ivar-style reads with no CoreSimulator dispatch that
could plausibly block, and are only ever used internally by `native-simctl.ts`'s `toDeviceInfo()`
to shape a `SimDeviceInfo` object — never called as a standalone slow operation.

**`Spawn` (`coresim.mm`) needs more than `RunAsync<T>`'s one-shot resolve**, since a spawned
process's exit can arrive long after the initial promise (carrying the pid) already resolved. It
combines `RunAsync<SpawnResult>` (resolves once, with `{pid, stdoutFd, stderrFd}`) with a
`Napi::ThreadSafeFunction` created *before* queuing the async work (must happen on the main
thread), captured by value into both the work lambda and the `terminationHandler` block CoreSimulator
invokes later from its own internal dispatch queue — `ThreadSafeFunction` has no ARC/RAII-style
auto-release on destruction (copying it just copies a raw handle), so exactly one `.Release()` call
per `.New()` is required on every path (success, native throw, and a spawn that never actually
started). `stdout`/`stderr` are always CoreSimulator-owned pipes this function creates itself, not
whatever `options` the caller passed (see "Empirically confirmed behavior" for why, and for the
`dup()`/write-end-closing details this depends on). `terminationHandler`'s raw wait-status is
decoded (`WIFEXITED`/`WEXITSTATUS`/`WIFSIGNALED`/`WTERMSIG`) inside the `ThreadSafeFunction`'s
callback specifically, since only that runs on the main thread where a `Napi::Value` can be built.

`GetBootStatus` is a much simpler `RunAsync<id>` binding wrapping `-[SimDevice bootStatus]` (see
`sim_device.h`/`.mm`'s `DeviceBootStatus`/`BootInfoStatus`/`BootInfoIsTerminal`) — `toValue` returns
`null` for a nil `SimDeviceBootInfo` (never booted) or `{status, isTerminal}` otherwise. See
"Empirically confirmed behavior" for what this actually tracks and why it exists alongside `state`.

### TypeScript layer (`src/`)

- **`native-simctl.ts`** — the `NativeSimctl` core: constructor (never throws — see below),
  `static frameworkVersion()`, and the `_`-prefixed internal helpers
  `_serviceContext()`/`_deviceSet()`/`_findDevice()` (not `private` — TS enforces that only within
  the class body, and every mixin function needs to call them from outside it; `_`-prefixed and
  `@internal`-tagged instead, so they're excluded from public docs without actually being
  inaccessible). `_serviceContext()` memoizes the **in-flight promise** (not just its resolved
  value) from `sharedServiceContext`, so concurrent callers before the first resolution still only
  trigger one native call. Loads the addon via `node-gyp-build` (see `utils/pkg-root.ts`).
- **`commands/*.ts`** — `NativeSimctl`'s actual public method surface, grouped by topic
  (`lifecycle`/`app`/`interaction`/`keychain`/`ui`/`permissions`/`darwin-notification`/`spawn`) and
  mixed into the class via `Object.assign(NativeSimctl.prototype, ...)` at the bottom of
  `native-simctl.ts` — mirroring `@appium/base-driver`'s own `BaseDriver`/`basedriver/commands/*.ts`
  split. Each module's functions take `this: NativeSimctl` (never arrow functions — arrow functions
  can't take a `this` parameter) and declares a `declare module '../native-simctl.js' { interface
  NativeSimctl { ... } }` augmentation so `NativeSimctl`'s type includes methods it doesn't
  textually define; `native-simctl.ts` also bare-imports (`import './commands/x.js'`) every command
  module purely for this augmentation's side effect — the named function imports used in
  `Object.assign` alone aren't enough to pull the augmentation into `tsc`'s emitted `.d.ts` import
  graph. Together these mirror **the same public method surface as `node-simctl`'s `Simctl`
  class** (`bootDevice`, `shutdownDevice`, `eraseDevice`, `deleteDevice`, `getEnv`, `installApp`,
  `removeApp`, `launchApp`, `terminateApp`, `isAppInstalled`, `appInfo`, `installedApps`, `openUrl`,
  `setLocation`, `pushNotification`, `addCertificate`, `addRootCertificate`, `resetKeychain`,
  `getAppearance`/`setAppearance`, `getIncreaseContrast`/`setIncreaseContrast`,
  `getContentSize`/`setContentSize`, `grantPermission`/`revokePermission`/`resetPermission`,
  `createDevice`, `deleteDevice`, `spawnProcess`, `getDevices`, `getSupportedDeviceTypes`,
  `getSupportedRuntimes`) so a consumer like `appium-ios-simulator` can swap its `Simctl`
  construction for `NativeSimctl` with minimal call-site churn — plus `getBootStatus()`/
  `waitForBoot()`, which `node-simctl` has no equivalent of at all: `simctl bootstatus` is a CLI
  subcommand `node-simctl`'s own `startBootMonitor()` only ever shells out to and parses stdout
  from, whereas this addon exposes the same underlying `SimDeviceBootInfo` signal directly (see
  "Empirically confirmed behavior"). `waitForBoot()` requires the device to already be `Booting`/
  `Booted` (throws otherwise — there's nothing to monitor) and returns immediately if it's already
  fully settled, via `asyncbox`'s `waitForCondition` (a **real** `dependencies` entry, not just a
  test-only one, since this is `src/` production code — its first condition check runs immediately
  with no initial delay, which is what makes the "already booted" fast path work for free). Devices
  are addressed by UDID;
  every method re-resolves the native device handle from the live device set (via `_findDevice()`)
  rather than caching it. Every method is `async`/`Promise`-returning, matching the addon's own
  fully-async surface (see Native layer above) and `node-simctl`'s own fully-async shape.
  `commands/spawn.ts` is the one deliberate method-surface divergence from `node-simctl` and also
  the one command module that exports more than its command function: `spawnProcess` resolves to a
  live `SpawnedProcess` handle (also defined in this file) — an `EventEmitter` wrapping what
  `NativeDeviceHandle.spawn()` resolves with: `stdout`/`stderr` as real `fs.ReadStream`s
  (`fs.createReadStream({fd})` over already-`dup()`'d fds — no native streaming plumbing needed
  once handed a real fd, libuv does it), `exitCode`/`signalCode` (`null` until a single `'exit'`
  event fires, decoded on the native side — see Native layer above), and `kill()` (a thin wrapper
  over `process.kill(pid, signal)`, safe because a spawned process's pid is a real host OS pid —
  see "Empirically confirmed behavior") — rather than `node-simctl`'s buffered
  `TeenProcessExecResult`, since the underlying native call already supports this and a caller can
  always `await`-drain the streams for the old buffered behavior. `spawnProcess()` constructs
  `SpawnedProcess` after `device.spawn()`'s promise resolves, wiring the native exit callback to
  the instance's internal `_handleExit()` — safe because that callback cannot fire before the
  process has even started, i.e. strictly after the constructing code has already run.
- **`errors.ts`** — `NativeSimError` base + `NativeSimUnavailableError`/`NativeSimDispatchError`/
  `NativeSimOperationError`, and `wrapNativeError()` which maps a raw error surfaced by the addon
  (identified by its `.name`) to the matching typed subclass.
- **`types.ts`** — the public `SimDeviceState`/`SimDeviceInfo`/`SimDeviceTypeInfo`/`SimRuntimeInfo`/
  `SimBootStatus`/`SimBootInfo`/`SpawnOptions` types `index.ts` re-exports, plus the
  `NativeDeviceHandle`/`NativeDeviceSetHandle`/
  `NativeServiceContextHandle`/`NativeCoreSimModule`/`NativeSpawnResult`/`NativeSpawnExitCallback`
  interfaces describing the native addon's own exports — internal to `native-simctl.ts`/
  `commands/*.ts`, never re-exported. `SpawnOptions` only types the two keys confirmed safe
  (`arguments`/`environment`, see "Empirically confirmed behavior") — `stdin`/`stdout`/`stderr` are
  deliberately absent from the type, since the addon always manages them itself now (see Native
  layer above).
- **`utils/`** — a barrel (`index.ts` re-exports every sibling file) of small, dependency-free
  helpers with no business logic of their own: `pkg-root.ts` (`getPkgRoot()`/`PACKAGE_NAME`, infra
  copied verbatim from `appium-ios-tuntap`'s pattern) and `run-catching.ts` (`runCatchingAsync()`,
  moved out of `native-simctl.ts` since `commands/*.ts` mixins importing it from there — the very
  file that imports *them* — was a real circular-dependency smell, even though TS/Node handle it
  fine mechanically; `utils/` only ever gets imported *by* `native-simctl.ts`/`commands/*.ts`,
  never the reverse). `native-simctl.ts` and every `commands/*.ts` mixin import from
  `./utils/index.js`/`../utils/index.js`, not the individual files, to keep a single, stable
  barrel import path regardless of how the helpers themselves get reorganized later.

### Tests and CI

`test/unit` covers everything read-only (device/type/runtime listing, error mapping) — safe to run
on any macOS host with Xcode installed. `test/integration` covers the mutating paths (boot,
shutdown, create, delete), validated across a matrix of Xcode/CoreSimulator and simulator-runtime
versions — mirroring `appium-ios-simulator`'s `functional-test.yml`, which pairs specific Xcode
versions with compatible macOS runner images via `maxim-lobanov/setup-xcode` and reads
`MOBILE_OS_VERSION`/`MOBILE_DEVICE_NAME` env vars set per matrix entry:

- **Xcode/CoreSimulator version** (the axis that matters most for this addon — a different Xcode
  ships a different bundled CoreSimulator build, i.e. different class/selector availability for
  `safe_dispatch` to resolve) is a **CI job matrix** in `integration-test.yml`: parallel jobs, each
  selecting a different Xcode via `maxim-lobanov/setup-xcode` on a compatible arm64 macOS runner
  image, mirroring `appium-ios-simulator`'s exact `(xcodeVersion, platform)` pairs.
- **Simulator runtime version** (a single Xcode can have more than one iOS runtime installed — this
  dev machine has two) is an **in-test loop** in `coresim-integration.spec.ts`:
  `availableRuntimeFixtures()` enumerates every runtime with an existing (compatible) device type
  and runs a `describe` block per runtime, each with its own throwaway device created/booted once
  in a `before` hook and shared by that runtime's checks, torn down once in `after` — never a
  developer's pre-existing simulators.

Real simulator boot on a GitHub Actions runner is far slower than on real hardware
(`appium-ios-simulator`'s own e2e suite budgets up to 16 minutes for a single CI boot —
`test/functional/helpers.ts`'s `LONG_TIMEOUT`), so the runtime loop itself is also gated on
`process.env.CI` (set by GitHub Actions, and explicitly re-set in `shared.yml` so this doesn't
depend on that default): **in CI, every available runtime is exercised** (that set is small and
controlled per runner image); **locally, only the first is** (fast dev loop, regardless of how many
old runtimes have accumulated on a real machine over time). Reproduce the CI behavior locally with
`CI=true npm run test:integration`. `test:integration`'s `--test-timeout` is set generously (20
minutes) in `package.json` to match; `integration-test.yml`'s job-level `timeout-minutes: 30` is a
backstop covering one Xcode version's worth of runtimes.

`coresim-integration.spec.ts`'s per-runtime `describe` block covers **most** of `NativeSimctl`'s
public surface against the one shared throwaway device — never creating or rebooting a second
simulator just to reach a method, since a real boot is the expensive part of this suite:
lifecycle (create/boot/getenv/erase — `eraseDevice` runs last, since it requires `Shutdown` and
leaves the device that way), location/Darwin notifications (post + get/set state), UI settings
(appearance/increase-contrast/content-size), keychain, `pushNotification`, `spawnProcess`
(streaming + `kill()`), and a `grantPermission`/`revokePermission`/`resetPermission` check that
verifies the actual persisted effect by reading the row straight out of the simulator's own TCC.db
(see "Empirically confirmed behavior"), not just that the call didn't throw. App-lifecycle checks
(`installApp`/`isAppInstalled`/`appInfo`/
`installedApps`/`launchApp`/`terminateApp`/`removeApp`) and `openUrl` are gated to iOS runtimes
only (`isIOSRuntime()`) since tvOS/watchOS/visionOS can't install an iOS `.app` or don't ship a
general-purpose browser. `test/fixtures.ts`'s `getUIKitCatalogPath()` downloads and caches the
same pre-built, simulator-signed `UIKitCatalog-iphonesimulator.app` fixture
`appium-xcuitest-driver`'s own test suite uses (`test/setup.ts` there,
`github.com/appium/ios-uicatalog`'s v4.0.1 release) — building an installable `.app` from scratch
isn't reliably reproducible across Xcode versions, and this one's already vetted; cached under
`test/fixtures/` (gitignored, resolved via `getPkgRoot()` so the cache path doesn't depend on
whether the caller is the TS source or the compiled `lib/` output) and downloaded at most once
per process regardless of how many iOS runtimes end up using it.

`binding.gyp`'s `WARNING_CFLAGS` (`-Wall -Wextra`, only `-Wno-unused-parameter` suppressed) plus
`GCC_TREAT_WARNINGS_AS_ERRORS: YES` apply to every generator gyp drives on macOS (`make`, used by
the normal `node-gyp rebuild`/`npm install` path, and `xcode`) — a warning fails the addon build
either way. `npm run build:addon:xcodebuild` (`node-gyp configure -- -f xcode` + `xcodebuild
-target coresim -configuration Release build`) exercises this through Xcode's own build system
specifically, not just `make`, since that's the toolchain `run-cpp-format-check`'s sibling gate,
`run-xcodebuild-check` (`shared.yml`), actually uses in CI — wired into both `unit-test.yml` (once,
against the runner's default Xcode) and `integration-test.yml`'s per-Xcode-version matrix (cheap to
repeat there since it only compiles, no simulator boot), so a new warning introduced by a *specific*
Xcode/clang version's stricter `-Wall`/`-Wextra` is caught against that version, not just the
runner default.

### Empirically confirmed behavior worth knowing

- **`deleteDevice:error:` is eventually consistent.** It returns success synchronously, but the
  device's actual removal (filesystem cleanup) happens on a background queue — confirmed by
  testing (`test/integration`) that the deleted UDID can still appear in `devices()` for a brief
  window (observed up to ~500ms) immediately after a successful `deleteDevice` call. Callers that
  need to confirm removal (as the integration test does) must poll rather than check once.
- **`createDeviceWithType:runtime:name:error:` does not return in the `Creating` state.** It's
  synchronous, and by the time it returns the device has already settled to `Shutdown`.
- **`eraseContentsAndSettingsWithError:` requires the device to already be `Shutdown`.** Calling it
  on a `Booted` device fails with `NativeSimOperationError` (`domain:
  com.apple.CoreSimulator.SimError`, `code: 405`, `"Unable to erase contents and settings in
  current state: Booted"`) rather than shutting it down first — callers must `shutdownDevice()`
  before `eraseDevice()`.
- **`bootAsyncWithOptions:completionQueue:completionHandler:`'s completion firing doesn't guarantee
  a subsequent `devices()` read already reflects `Booted`.** The same class of eventual consistency
  as `deleteDevice` above — observed once in CI (`integration-test.yml`, Xcode 16.4, iOS 26.0
  runtime): the boot promise resolved with no error, but a `devices()` call ~18ms later still
  reported `Booting`. `test/integration/coresim-integration.spec.ts`'s `waitUntilState()` polls for
  this the same way `waitUntilDeleted()` does, rather than asserting the state once.
- **`SimDeviceState` reaching `Booted` is not the same as "the simulator has actually finished
  booting" — `simctl bootstatus` itself checks a completely different, far more granular signal,
  and the gap between the two was measured at 20+ seconds.** Confirmed at runtime against the
  loaded framework: the `SimDeviceBootInfo` class exposes `status`/`isTerminalStatus`/`info`
  properties, and `simctl bootstatus` itself polls this same `-[SimDevice bootStatus]` signal —
  never `SimDeviceState` — reporting phases as "Waiting on Data Migration"/"Waiting on System
  App"/"Waiting on BackBoard"/"Finished". Empirically timed on
  a real boot: `SimDeviceState` became `Booted` after 336ms, but the *same* boot didn't reach
  `bootstatus`'s "Finished"/`isTerminalStatus=YES` signal until ~22.7s later — `state` only means
  the OS kernel/launchd has started; data migration and system-app (SpringBoard) startup are
  unaccounted for. Confirmed `status` values: `0` = Booting, `2` = WaitingOnDataMigration, `4` =
  WaitingOnSystemApp, `0xFFFFFFFF` = Finished (the only terminal one observed) — "WaitingOnBackboard"
  is a real phase name (seen in `simctl bootstatus`'s own output) whose numeric value wasn't triggered in
  testing; not every boot passes through every phase (one run went straight from Booting to
  WaitingOnSystemApp, skipping migration entirely). `bootStatus` is also confirmed **not to reset on
  shutdown** — a device shut down after a completed boot still reports its *previous* session's
  `isTerminalStatus=YES`/`status=Finished`, so a caller must check `SimDeviceState` too, not
  `isTerminalStatus` alone, to know "currently booted" vs. "remembering an old boot". `getenv:error:`
  is a confirmed **exception** to needing full settlement — since it's a plain read of the device's
  own on-disk `data` directory path rather than anything that queries a live guest-OS process, it
  succeeded immediately in testing even while `bootStatus` was still `{status: 0, isTerminal:
  false}` — but other endpoints aren't guaranteed to be as graceful, which is why
  `NativeSimctl.getBootStatus()`/`waitForBoot()` (`commands/lifecycle.ts`) exist, and why
  `coresim-integration.spec.ts`'s `before()` hook now calls `waitForBoot()` right after
  `bootDevice()` so every check in that runtime's block runs against a genuinely, fully-settled
  simulator — this had a nice side effect in practice: a `pushNotification()` call that used to take
  ~19s (apparently a lazily-started daemon's own cold-start cost) dropped to ~40ms once boot
  settlement was guaranteed to have already happened first.
- **`spawn()`'s options dictionary keys, confirmed.** Dictionary key names aren't part of a
  selector's type encoding, so they can't be confirmed the same way method signatures are — but
  the framework exports each key as a global `NSString* const` symbol, resolvable by name at
  runtime via `dlsym` against the already-loaded framework. Confirmed present:
  `arguments` ([string] — **fully replaces argv, including argv[0]**; the `path` argument only
  selects the executable, it is not auto-prepended — verified by spawning a probe binary that
  dumps its own argv to a file), `environment` ({string: string} — merged additively into the
  spawned process's environment, verified the same way). The spawned process's cwd defaults to the
  device's `data` directory (`~/Library/Developer/CoreSimulator/Devices/<udid>/data/`), confirmed
  by a relative-path argument landing there.
- **`stdout`/`stderr` need an `NSFileHandle`/XPC file descriptor/`NSNumber`, never a path string —
  and a malformed value crashes the whole process, bypassing `safe_dispatch.h` entirely.** Passing
  a plain string for `stdout` throws `NSInternalInconsistencyException` ("File handle type
  '__NSCFString' is not XPC_TYPE_FD, NSFileHandle, or NSNumber") from inside
  `-[SimLaunchHostClient spawnInSession:...]`, called via `bootstrapQueueSync:`, which
  (empirically) executes on a *different* underlying thread than the one that called
  `spawnWithPath:options:...` and is wrapped by `SafeInvoke`'s `@try`/`@catch` — an NSException
  raised on a different thread than the `@try` block cannot be caught by it, so this crashes the
  whole Node process instead of surfacing as a catchable error. This is why `SpawnOptions`
  (`src/types.ts`) deliberately has no `stdin`/`stdout`/`stderr` keys, and why `coresim.mm`'s
  `NativeDevice::Spawn` always constructs its own `NSPipe`s and passes their `fileHandleForWriting`
  for `stdout`/`stderr` — verified empirically (a standalone probe against a live simulator, before
  touching the addon) that an `NSFileHandle` wrapping a pipe's write end is a safe, accepted value,
  with genuine live/incremental delivery (not buffered until exit) once the read end is wrapped in
  a Node stream.
- **A pipe's write end must be closed in *this* process right after the spawn call succeeds, or
  the read end never sees EOF.** Confirmed via the same probe: with `[stdoutPipe.fileHandleForWriting
  closeFile]` omitted, `availableData` never returns empty even after the child (the simulator-side
  process) exits, since our own dangling copy of the write end keeps the pipe "open" from the
  reader's perspective. `coresim.mm`'s `Spawn` closes both write ends immediately after the
  `spawnWithPath:...` call returns, on every code path (success, native throw, and `pid <= 0`).
- **The fd handed to JS must be an independent `dup()`, not the `NSFileHandle`'s own fd.** The
  `NSPipe`/`NSFileHandle` objects created inside `Spawn()`'s work lambda go out of scope (and get
  deallocated by ARC) once that lambda returns; `NSFileHandle`'s dealloc closes its underlying fd,
  which would otherwise yank the fd out from under the `fs.createReadStream({fd})` JS already
  handed off. `dup()`-ing the read end's fd before returning decouples the two lifetimes —
  confirmed leak-free across repeated spawns (`lsof -p` showed a flat fd count over 15 sequential
  spawns).
- **`spawnWithPath:...`'s `terminationHandler` receives a raw POSIX `wait(2)`-style status, not a
  plain exit code.** Confirmed empirically: a normal `exit(127)` arrived as `32512` (`127 << 8`,
  i.e. `WEXITSTATUS`-encoded), and a `SIGTERM`-killed process arrived as the bare signal number
  `15`. `coresim.mm`'s `Spawn` decodes this with `WIFEXITED`/`WEXITSTATUS`/`WIFSIGNALED`/
  `WTERMSIG` before ever building a `Napi::Value`, matching `child_process.ChildProcess`'s own
  `(code, signal)` exit shape.
- **A spawned process's pid is a real host OS process id, directly `kill(2)`-able.** The simulator
  shares the host kernel and filesystem (this is also why file-path arguments/redirects work at
  all) — confirmed by spawning `/bin/sleep 30` and killing it with the raw `kill(2)` syscall from
  an entirely separate host process, with the termination handler firing `SIGTERM` in response.
  `SpawnedProcess.kill()` is therefore just `process.kill(this.pid, signal)` — no native call
  needed.
- **`SpawnedProcess`'s `'exit'` event and its `stdout`/`stderr` streams' own `'end'` are
  independent, unsynchronized signals — `'exit'` can fire first.** `'exit'` arrives via the native
  `ThreadSafeFunction`/GCD termination handler; `stdout`/`stderr` delivery is driven separately by
  libuv polling the `dup()`'d fd. Observed in CI (not locally): a test asserting on accumulated
  `stdout` content right after `'exit'` fired saw `''` — the stream hadn't delivered (or even
  started delivering) its buffered data yet. A caller that needs complete output must wait for the
  stream's own `'end'` too, not just `'exit'` — `test/integration/coresim-integration.spec.ts`'s
  spawn test now does `Promise.all([once(proc, 'exit'), once(proc.stdout, 'end')])`.
- **`sendPushNotificationForBundleID:jsonPayload:error:`'s second parameter is actually
  `NSDictionary*`, not `NSData*` despite the selector's "json" naming — a real bug this addon
  shipped with, found while adding integration test coverage for `pushNotification()`.** ObjC type
  encoding (what selector-signature recovery reads) can't distinguish object *pointer
  classes* — every object type encodes identically as `@` — so the original signature recovery
  guessed `NSData*` (a plausible reading of "jsonPayload"). Passing `NSData` (whether raw JSON-text
  UTF8 bytes, an XML plist, or a binary plist — all three tried) crashes with
  `NSInvalidArgumentException: -[NSConcreteData objectForKeyedSubscript:]: unrecognized selector`,
  confirmed with a standalone probe calling the selector directly. Passing the `NSDictionary` object
  itself (no serialization at all) works. `pushNotification()` was completely broken for every
  payload before this fix — `coresim.mm`'s `SendPushNotification` now converts the JS payload
  object straight to `NSDictionary` via `JsValueToNSObject` (the same bridge `options` dicts use
  elsewhere), never through `JSON.stringify`+`NSData`.
- **CoreSimulator's own `setPrivacyAccessForService:bundleID:granted:error:` fails with
  `NSPOSIXErrorDomain`/`EPERM` when called from this addon, even with a real installed bundle and a
  valid permission name — while `xcrun simctl privacy grant <perm> <bundleId>` succeeds for the
  exact same device/bundle from the same unprivileged shell user.** Confirmed empirically, including
  via a standalone probe calling that selector directly (bypassing this addon entirely) — not an
  argument-marshaling bug like the two findings above. The real `simctl` binary is signed by Apple;
  a plain Node.js process calling the identical private CoreSimulator method is not, and
  privacy/TCC-database writes through that method are gated on the *calling process*'s code
  signature/entitlements, checked at the OS level (or via an XPC service like `tccd`) below where
  our own argument marshaling could intervene.
  **`grantPermission`/`revokePermission`/`resetPermission` therefore bypass that method entirely**
  (`native/tcc_privacy.mm`): they write directly to the simulator's own TCC (privacy) SQLite
  database at `<device dataPath>/Library/TCC/TCC.db` — `DELETE FROM access WHERE service=? AND
  client=? AND client_type=0`, then (unless resetting) `INSERT`/`REPLACE INTO access (...)` with the
  granted/denied value. This is a plain file write, not a call through the entitlement-gated XPC
  path, so it works from an unsigned process. Schema is checked at runtime (`PRAGMA
  table_info(access)` for an `auth_value` column) rather than assumed from an OS version threshold,
  since the schema tracks the *simulator's* iOS release, not the host's: iOS 14+ uses an
  `auth_value` int column (`0`=denied, `2`=granted; `kTCCServicePhotos` rows additionally use
  `auth_version=2`), older releases use a boolean `allowed` column. Opening the database uses
  `SQLITE_OPEN_READWRITE` only (no `_CREATE`) so a device that's never been booted (TCC.db doesn't
  exist yet) fails with a clear error instead of silently creating an empty, schema-less database;
  `sqlite3_busy_timeout` (5s) handles the simulator's own `tccd` transiently holding the file open,
  rather than a manual sleep/retry loop. `location`/`location-always` are **not** supported this way
  — CoreLocation simulation has its own subsystem, not a plain TCC row — so `SimPermissionService`
  (`types.ts`) deliberately excludes them. `commands/permissions.ts` maps each friendly service name
  (`camera`, `contacts`, `photos`, ...) to its internal `kTCCService*` identifier before this call.
  `binding.gyp` links `-lsqlite3` (a public, stable system library — unlike `CoreSimulator.framework`
  this needs no `dlopen`/availability guard) and builds `native/tcc_privacy.mm`.
- **A throwaway self-signed cert (`openssl req -x509 ...`, content irrelevant) is enough to
  exercise `addCertificate`/`addRootCertificate`/`resetKeychain`** — confirmed to succeed
  regardless of the cert's actual validity/trust chain. Adding the *same* cert content twice to
  the *same* store (e.g. `addCertificate` called twice in a row with identical bytes) rejects as a
  duplicate — confirmed while testing this; `addCertificate` then `addRootCertificate` with the
  same content is fine, since they're different stores.
- **`addCertificate`/`addRootCertificate` accept a `Buffer` of raw certificate content, not just a
  file path** — `commands/keychain.ts`'s `resolveCertPath()` writes a `Buffer` to a throwaway temp
  file (cleaned up in a `finally`) before delegating to the same native call, which only ever
  accepts a path — mirroring how `node-simctl`'s own keychain commands handle raw cert content.
- **`shutdownDevice()` on an already-`Shutdown` device rejects** (`"Unable to shutdown device in
  current state: Shutdown"`) rather than being a no-op — confirmed empirically. Test cleanup that
  might run after a test which already shut the device down (e.g. the `eraseDevice` test, which
  needs `Shutdown` first) must check current state before calling `shutdownDevice()` again, rather
  than rebooting the device just to shut it down a second time.

### Known gaps / deliberately out of scope for this pass

- **Multi-Xcode-version resolution is partial**: `NativeSimctl`'s constructor passes `developerDir`
  through to `sharedServiceContextForDeveloperDir:error:` (defaulting to `xcode-select -p`), but
  does **not** yet replicate `simctl`'s wrapper-script behavior of comparing the shared
  framework's `CFBundleVersion` against the version the active Xcode expects and running
  `xcodebuild -runFirstLaunch` to upgrade it — unlike `appium-ios-tuntap`, Xcode does not bundle
  its own copy of `CoreSimulator.framework` (verified: no `CoreSimulator.framework` exists inside
  `Xcode.app` on this machine), so where that "expected version" marker actually lives needs
  follow-up research before implementing the auto-upgrade check.
- **`spawn()`'s writable `stdin` is not implemented.** `NativeSpawnResult`/`SpawnedProcess` only
  wire up `stdout`/`stderr`; a caller cannot currently write to the spawned process's stdin. The
  mechanism (an `NSFileHandle`-wrapped pipe, symmetric to stdout/stderr — see "Empirically
  confirmed behavior" below) would extend cleanly if needed. `binpref`, `standalone`,
  `wait_for_debugger`, `enableCheckedAllocations` (also real `SimDeviceSpawnKey*` dictionary keys,
  confirmed the same way — see above) remain unverified and unexposed.
- **Bulk shutdown-all (`killAllSimulators`), screenshot capture (`SimDeviceIO`), TCC permission
  *state reading*, WebInspector socket discovery, and the remaining host-side CLI tools
  (`PlistBuddy`/`plutil`/`defaults`/`zip`/`open`/`kill`/`lsappinfo`) are out of scope** — see
  `/Users/elf/Desktop/appium-simulator-native-migration-plan.md` (Phases 3, 5, 6, 7) for the full
  migration plan this package implements Phases 1–2 of.
