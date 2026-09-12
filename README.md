# @appium/coresim

Native Node.js bindings to Apple's `CoreSimulator.framework` — the private, unsigned-but-unrestricted
framework that `simctl` and Xcode are themselves built on. This package drives
`SimServiceContext`/`SimDeviceSet`/`SimDevice` directly, in-process, instead of shelling out to the
`simctl` CLI.

Installs on any platform — `npm install` never fails here, since the TS/error-class surface is
plain JS — but native functionality only works on **macOS**, since `CoreSimulator.framework`
doesn't exist anywhere else. Anywhere else, constructing `NativeSimctl` still succeeds; the first
call to any method (or to `NativeSimctl.frameworkVersion()`) rejects with a typed
`NativeSimUnavailableError` instead of building or crashing. (Prebuilds currently ship for arm64
only; an Intel Mac compiles from source instead.)

Every method that can trigger a CoreSimulator dispatch is `async` — the native layer runs it on a
background thread, so a slow install/erase/create/etc. never blocks Node's event loop.

## Why

`appium-ios-simulator` currently controls the Simulator by shelling out to `simctl` (via `node-simctl`)
and a handful of other CLI tools (`applesimutils`, `PlistBuddy`, `sqlite3`, `lsof`, ...). Every one of
those is either a thin wrapper over a `CoreSimulator.framework` Objective-C method, or a separate
subsystem this package doesn't touch. Calling the framework directly removes the CLI-process overhead,
replaces stderr string-matching with structured `NSError` handling, and removes third-party binary
dependencies where a native equivalent exists.

## Design

`CoreSimulator.framework` ships no public headers. Every class and selector this package calls is
resolved **dynamically at runtime** (`NSClassFromString`/`NSSelectorFromString`), never linked
statically, and every dispatch is checked (`respondsToSelector:`) and exception-guarded before it runs.
A missing class/selector or a caught `NSException` surfaces as a catchable `NativeSimUnavailableError`
in JavaScript — never a process crash — so drift across Xcode/CoreSimulator versions degrades
gracefully instead of taking the process down.

See `CLAUDE.md` for the full architecture and file layout.

## Status

Early scaffolding — foundation (native dispatch layer, `SimServiceContext`/`SimDeviceSet` bootstrap) plus
core device lifecycle and app-management methods. Not yet published; not yet consumed by
`appium-ios-simulator`.
