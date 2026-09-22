# @appium/coresim

Fast, native control of the iOS/tvOS/watchOS/visionOS Simulator from Node.js — no `simctl`
subprocess, no CLI output to parse.

## Why

Most tools drive the Simulator by shelling out to `simctl` and parsing its text output.
`@appium/coresim` talks to the same underlying system directly, in-process. That means:

- **Faster** — no process spawn per call.
- **More reliable** — real errors instead of scraped stderr strings.
- **Async by design** — every call returns a `Promise` and never blocks your app.

## Install

```sh
npm install @appium/coresim
```

Works on any platform to install, but simulator control requires **macOS**. On other platforms
(or when the Simulator isn't available), calls reject with a clear `NativeSimUnavailableError`
instead of crashing.

## Usage

```ts
import {NativeSimctl} from '@appium/coresim';

const sim = new NativeSimctl();

const devices = await sim.getDevices();
console.log(devices.map((d) => `${d.name} (${d.state})`));

const device = await sim.createDevice(
  'My Test Device',
  'com.apple.CoreSimulator.SimDeviceType.iPhone-15',
  'com.apple.CoreSimulator.SimRuntime.iOS-17-4',
);

await sim.bootDevice(device.udid);
await sim.waitForBoot(device.udid); // waits until the simulator is fully ready, not just "booted"

await sim.installApp(device.udid, '/path/to/MyApp.app');
await sim.launchApp(device.udid, 'com.example.MyApp');

await sim.shutdownDevice(device.udid);
await sim.deleteDevice(device.udid);
```

## What it can do

- **Devices** — list, create, delete, boot, shut down, and erase simulators; check real boot
  readiness with `getBootStatus()`/`waitForBoot()`.
- **Apps** — install, remove, launch, terminate, and inspect apps.
- **Processes** — spawn a process on the simulator and stream its stdout/stderr live.
- **Screen capture** — screenshots, video recording to a file, and a real-time encoded video
  stream — optionally with the device's own audio, muxed into the recording or interleaved into
  the stream.
- **Simulator settings** — appearance (light/dark), accessibility (increase contrast, content
  size), location, and permissions.
- **Extras** — keychain certificates, push notifications, and Darwin notifications.

## Status

Early stage: core device and app lifecycle is implemented and tested; broader coverage is in
progress.

See [`CLAUDE.md`](./CLAUDE.md) for architecture details.
