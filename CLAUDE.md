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
  it's why the addon always manages those pipes itself rather than accepting them as options.
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

## Known gaps

- No handling of a CoreSimulator/Xcode version mismatch requiring an upgrade (the way `simctl`'s own
  wrapper does).
- `spawnProcess` has no writable `stdin`.
- No WebInspector socket discovery yet.
