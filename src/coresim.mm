// N-API glue: exposes SimServiceContext/SimDeviceSet/SimDevice as JS-facing classes. All actual
// dynamic dispatch lives in native/*.mm (safe_dispatch-guarded); this file only translates
// JS <-> Objective-C values, decides sync vs. async exposure, and reports errors/results back to
// Node.
//
// Every method that can trigger a CoreSimulator dispatch (i.e. everything except the handful of
// trivial in-memory property getters below) is async: work runs in a RunAsync/RunAsyncVoid
// worker on a libuv threadpool thread (async_bridge.h), so a slow install/erase/create/etc. never
// blocks Node's event loop, matching how boot already worked before this file's rewrite.

#include <napi.h>

#import <Foundation/Foundation.h>

#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#include "native/async_bridge.h"
#include "native/nserror_bridge.h"
#include "native/objc_runtime.h"
#include "native/sim_device.h"
#include "native/sim_device_set.h"
#include "native/sim_pasteboard.h"
#include "native/sim_screenshot.h"
#include "native/sim_service_context.h"
#include "native/tcc_privacy.h"
#include "native/value_bridge.h"

namespace coresim {

namespace {

// Boxes an `id` behind a Napi::External so it survives the single synchronous call into an
// ObjectWrap constructor (see NewInstance below in each class).
Napi::Object WrapExternalId(Napi::Env env, const Napi::FunctionReference& ctor, id value) {
  __unsafe_unretained id boxed = value;
  return ctor.New({Napi::External<void>::New(env, &boxed)});
}

id UnwrapExternalId(const Napi::CallbackInfo& info) {
  return *static_cast<__unsafe_unretained id*>(info[0].As<Napi::External<void>>().Data());
}

NSDictionary* OptionsArg(const Napi::CallbackInfo& info, size_t index) {
  if (info.Length() <= index || info[index].IsUndefined() || info[index].IsNull()) {
    return @{};
  }
  return (NSDictionary*)JsValueToNSObject(info.Env(), info[index]);
}

// Throws if `!ok && error`, for the common BOOL-returning NSError**-out-param shape — called from
// inside a RunAsync/RunAsyncVoid work lambda (background thread), never from the main thread.
void ThrowIfFailed(BOOL ok, NSError* error) {
  if (!ok && error != nil) {
    throw NSErrorException(error);
  }
}

// Mirrors coresim::TCCAuthStatus (tcc_privacy.h) as the string enum getPermission() resolves with
// — a plain string, not a raw int, since JS callers have no header to interpret the int against.
const char* TCCAuthStatusToString(TCCAuthStatus status) {
  switch (status) {
    case kTCCAuthDenied:
      return "denied";
    case kTCCAuthGranted:
      return "granted";
    case kTCCAuthLimited:
      return "limited";
    case kTCCAuthNotDetermined:
    default:
      return "unset";
  }
}

// dup() failure (e.g. EMFILE — the process fd table is full) — surfaced as a normal catchable
// error via ThrowIfFailed's own throw path, rather than an fd of -1 silently reaching JS.
NSError* MakeDescriptorError(NSString* which, int savedErrno) {
  return [NSError errorWithDomain:NSPOSIXErrorDomain
                             code:savedErrno
                         userInfo:@{
                           NSLocalizedDescriptionKey : [NSString
                               stringWithFormat:@"Failed to duplicate the spawned process's %@ file descriptor: %s",
                                                which, strerror(savedErrno)]
                         }];
}

// Plain data Spawn()'s work lambda (background thread) hands to its toValue callback (main
// thread) — see NativeDevice::Spawn below.
struct SpawnResult {
  int pid = 0;
  int stdoutFd = -1;
  int stderrFd = -1;
};

// Plain data for GetBootStatus/SupportedDeviceTypesMethod/SupportedRuntimesMethod's work lambdas
// to hand to their toValue callbacks. toValue always runs on the main thread (OnOK), never
// guarded by Execute()'s try/catch — the node-addon-api completion wrapper only catches
// Napi::Error there unless NODE_ADDON_API_CPP_EXCEPTIONS_ALL is defined (it isn't here), so a
// native accessor call from inside toValue could throw NativeSimUnavailableError/ObjCException
// uncaught and crash the process. Extracting these plain values in `work` instead keeps every
// native call inside the guarded stage; toValue only ever touches already-safe C++/Foundation
// primitives.
struct BootStatusResult {
  bool hasValue = false;
  unsigned int status = 0;
  bool isTerminal = false;
};

struct DeviceTypeEntry {
  std::string identifier;
  std::string name;
};

struct RuntimeEntry {
  std::string identifier;
  std::string name;
  std::string versionString;
};

// Node-API explicitly prohibits sharing an Environment's data across Environments (e.g. two
// worker_threads instances each `require()`-ing this addon) — each gets its own separate call
// into Init() below. A process-global `static Napi::FunctionReference` per class would let one
// Environment's object construction use a FunctionReference belonging to another (possibly
// already-torn-down) Environment, corrupting state or crashing Node. Storing these via
// Napi::Env::SetInstanceData/GetInstanceData instead keeps each Environment's constructors
// scoped to it, and cleans them up automatically (the default finalizer just `delete`s this) when
// that Environment tears down.
struct AddonInstanceData {
  Napi::FunctionReference deviceConstructor;
  Napi::FunctionReference deviceSetConstructor;
  Napi::FunctionReference serviceContextConstructor;
};

}  // namespace

class NativeDevice : public Napi::ObjectWrap<NativeDevice> {
 public:
  static void Init(Napi::Env env);
  static Napi::Object NewInstance(Napi::Env env, id device);
  explicit NativeDevice(const Napi::CallbackInfo& info);

  id device_;

 private:
  // Trivial in-memory accessors (no CoreSimulator dispatch that could block) — kept synchronous;
  // used internally by native-simctl.ts's toDeviceInfo(), never a slow operation on their own.
  Napi::Value Udid(const Napi::CallbackInfo& info) {
    return CatchToJs(info.Env(), [&]() -> Napi::Value {
      return Napi::String::New(info.Env(), DeviceUDID(device_).UUIDString.UTF8String);
    });
  }
  Napi::Value Name(const Napi::CallbackInfo& info) {
    return CatchToJs(info.Env(),
                     [&]() -> Napi::Value { return Napi::String::New(info.Env(), DeviceName(device_).UTF8String); });
  }
  Napi::Value State(const Napi::CallbackInfo& info) {
    return CatchToJs(info.Env(), [&]() -> Napi::Value {
      return Napi::Number::New(info.Env(), static_cast<double>(DeviceState(device_)));
    });
  }
  // deviceType/runtime are legitimately nil for a device whose runtime profile is no longer
  // installed (shows as "unavailable" in `simctl list devices`) — not an error, just unknown.
  Napi::Value DeviceTypeIdentifier(const Napi::CallbackInfo& info) {
    return CatchToJs(info.Env(), [&]() -> Napi::Value {
      id deviceType = DeviceDeviceType(device_);
      if (deviceType == nil) {
        return Napi::String::New(info.Env(), "");
      }
      return Napi::String::New(info.Env(), coresim::DeviceTypeIdentifier(deviceType).UTF8String);
    });
  }
  Napi::Value RuntimeIdentifier(const Napi::CallbackInfo& info) {
    return CatchToJs(info.Env(), [&]() -> Napi::Value {
      id runtime = DeviceRuntime(device_);
      if (runtime == nil) {
        return Napi::String::New(info.Env(), "");
      }
      return Napi::String::New(info.Env(), coresim::RuntimeIdentifier(runtime).UTF8String);
    });
  }

  // Bridges SimDevice's GCD-completion-block-based bootAsyncWithOptions:completionQueue:
  // completionHandler: — this is what replaces the CLI's bootstatus poll-until-timeout race with
  // a deterministic completion signal.
  Napi::Value Boot(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    id device = device_;
    NSDictionary* options = OptionsArg(info, 0);
    return RunAsyncVoid(env, [device, options]() {
      dispatch_semaphore_t sema = dispatch_semaphore_create(0);
      dispatch_queue_t queue = dispatch_queue_create("com.appium.coresim.boot", DISPATCH_QUEUE_SERIAL);
      __block NSError* capturedError = nil;
      BootAsync(device, options, queue, ^(NSError* error) {
        capturedError = error;
        dispatch_semaphore_signal(sema);
      });
      dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
      if (capturedError != nil) {
        throw NSErrorException(capturedError);
      }
    });
  }

  // Exposes the same underlying signal `simctl bootstatus` itself monitors (see sim_device.h's
  // DeviceBootStatus) — a separate, more granular progress indicator than `state`. Returns `null`
  // if the device has never been booted; otherwise `{status, isTerminal}`, confirmed empirically
  // to *not* reset on shutdown (see CLAUDE.md) — callers wanting "is this device currently and
  // fully booted" must check `state === Booted` too, not `isTerminal` alone.
  Napi::Value GetBootStatus(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsync<BootStatusResult>(
        info.Env(),
        [device]() -> BootStatusResult {
          id bootInfo = coresim::DeviceBootStatus(device);
          if (bootInfo == nil) {
            return {};
          }
          return {true, coresim::BootInfoStatus(bootInfo), static_cast<bool>(coresim::BootInfoIsTerminal(bootInfo))};
        },
        [](Napi::Env env, BootStatusResult result) -> Napi::Value {
          if (!result.hasValue) {
            return env.Null();
          }
          Napi::Object obj = Napi::Object::New(env);
          obj.Set("status", static_cast<double>(result.status));
          obj.Set("isTerminal", result.isTerminal);
          return obj;
        });
  }

  Napi::Value Shutdown(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsyncVoid(info.Env(), [device]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::Shutdown(device, &error), error);
    });
  }

  Napi::Value Erase(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsyncVoid(info.Env(), [device]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::Erase(device, &error), error);
    });
  }

  Napi::Value Getenv(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* name = @(info[0].As<Napi::String>().Utf8Value().c_str());
    return RunAsync<NSString*>(
        info.Env(),
        [device, name]() -> NSString* {
          NSError* error = nil;
          NSString* result = coresim::Getenv(device, name, &error);
          ThrowIfFailed(result != nil, error);
          return result;
        },
        [](Napi::Env env, NSString* result) -> Napi::Value {
          return Napi::String::New(env, result ? result.UTF8String : "");
        });
  }

  Napi::Value InstallApp(const Napi::CallbackInfo& info) {
    id device = device_;
    NSURL* url = [NSURL fileURLWithPath:@(info[0].As<Napi::String>().Utf8Value().c_str())];
    NSDictionary* options = OptionsArg(info, 1);
    return RunAsyncVoid(info.Env(), [device, url, options]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::InstallApp(device, url, options, &error), error);
    });
  }

  Napi::Value UninstallApp(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* bundleId = @(info[0].As<Napi::String>().Utf8Value().c_str());
    NSDictionary* options = OptionsArg(info, 1);
    return RunAsyncVoid(info.Env(), [device, bundleId, options]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::UninstallApp(device, bundleId, options, &error), error);
    });
  }

  Napi::Value LaunchApp(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* bundleId = @(info[0].As<Napi::String>().Utf8Value().c_str());
    NSDictionary* options = OptionsArg(info, 1);
    return RunAsync<int>(
        info.Env(),
        [device, bundleId, options]() -> int {
          NSError* error = nil;
          int pid = coresim::LaunchApp(device, bundleId, options, &error);
          ThrowIfFailed(pid > 0, error);
          return pid;
        },
        [](Napi::Env env, int pid) -> Napi::Value { return Napi::Number::New(env, pid); });
  }

  Napi::Value TerminateApp(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* bundleId = @(info[0].As<Napi::String>().Utf8Value().c_str());
    return RunAsyncVoid(info.Env(), [device, bundleId]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::TerminateApp(device, bundleId, &error), error);
    });
  }

  Napi::Value PropertiesOfApplication(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* bundleId = @(info[0].As<Napi::String>().Utf8Value().c_str());
    return RunAsync<NSDictionary*>(
        info.Env(),
        [device, bundleId]() -> NSDictionary* {
          NSError* error = nil;
          NSDictionary* result = coresim::PropertiesOfApplication(device, bundleId, &error);
          ThrowIfFailed(result != nil, error);
          return result;
        },
        [](Napi::Env env, NSDictionary* result) -> Napi::Value { return NSObjectToJsValue(env, result); });
  }

  Napi::Value InstalledApps(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsync<NSDictionary*>(
        info.Env(),
        [device]() -> NSDictionary* {
          NSError* error = nil;
          NSDictionary* result = coresim::InstalledApps(device, &error);
          ThrowIfFailed(result != nil, error);
          return result;
        },
        [](Napi::Env env, NSDictionary* result) -> Napi::Value { return NSObjectToJsValue(env, result); });
  }

  Napi::Value OpenUrl(const Napi::CallbackInfo& info) {
    id device = device_;
    NSURL* url = [NSURL URLWithString:@(info[0].As<Napi::String>().Utf8Value().c_str())];
    return RunAsyncVoid(info.Env(), [device, url]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::OpenURL(device, url, &error), error);
    });
  }

  Napi::Value SetLocation(const Napi::CallbackInfo& info) {
    id device = device_;
    double latitude = info[0].As<Napi::Number>().DoubleValue();
    double longitude = info[1].As<Napi::Number>().DoubleValue();
    return RunAsyncVoid(info.Env(), [device, latitude, longitude]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::SetLocation(device, latitude, longitude, &error), error);
    });
  }

  Napi::Value SendPushNotification(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* bundleId = @(info[0].As<Napi::String>().Utf8Value().c_str());
    NSDictionary* payload = (NSDictionary*)JsValueToNSObject(info.Env(), info[1]);
    return RunAsyncVoid(info.Env(), [device, bundleId, payload]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::SendPushNotification(device, bundleId, payload, &error), error);
    });
  }

  Napi::Value AddCertificate(const Napi::CallbackInfo& info) {
    id device = device_;
    NSURL* url = [NSURL fileURLWithPath:@(info[0].As<Napi::String>().Utf8Value().c_str())];
    BOOL trustAsRoot = info.Length() > 1 && info[1].As<Napi::Boolean>().Value();
    return RunAsyncVoid(info.Env(), [device, url, trustAsRoot]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::AddCertificate(device, url, trustAsRoot, &error), error);
    });
  }

  Napi::Value ResetKeychain(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsyncVoid(info.Env(), [device]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::ResetKeychain(device, &error), error);
    });
  }

  Napi::Value GetUIAppearance(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsync<long long>(
        info.Env(), [device]() -> long long { return CurrentUIInterfaceStyle(device); },
        [](Napi::Env env, long long style) -> Napi::Value {
          return Napi::Number::New(env, static_cast<double>(style));
        });
  }

  Napi::Value SetUIAppearance(const Napi::CallbackInfo& info) {
    id device = device_;
    long long style = info[0].As<Napi::Number>().Int64Value();
    return RunAsyncVoid(info.Env(), [device, style]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::SetUIInterfaceStyle(device, style, &error), error);
    });
  }

  Napi::Value GetIncreaseContrast(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsync<long long>(
        info.Env(), [device]() -> long long { return CurrentIncreaseContrastMode(device); },
        [](Napi::Env env, long long mode) -> Napi::Value { return Napi::Number::New(env, static_cast<double>(mode)); });
  }

  Napi::Value SetIncreaseContrast(const Napi::CallbackInfo& info) {
    id device = device_;
    BOOL enabled = info[0].As<Napi::Boolean>().Value();
    return RunAsyncVoid(info.Env(), [device, enabled]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::SetIncreaseContrastEnabled(device, enabled, &error), error);
    });
  }

  Napi::Value GetContentSize(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsync<long long>(
        info.Env(), [device]() -> long long { return CurrentContentSizeCategory(device); },
        [](Napi::Env env, long long category) -> Napi::Value {
          return Napi::Number::New(env, static_cast<double>(category));
        });
  }

  Napi::Value SetContentSize(const Napi::CallbackInfo& info) {
    id device = device_;
    long long category = info[0].As<Napi::Number>().Int64Value();
    return RunAsyncVoid(info.Env(), [device, category]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::SetContentSizeCategory(device, category, &error), error);
    });
  }

  Napi::Value GrantPermission(const Napi::CallbackInfo& info) { return SetPermission(info, YES); }
  Napi::Value RevokePermission(const Napi::CallbackInfo& info) { return SetPermission(info, NO); }

  // Writes directly to the simulator's own TCC.db instead of calling CoreSimulator's
  // setPrivacyAccessForService:bundleID:granted:error: — that private method requires the calling
  // process to hold an entitlement no ordinary npm package can obtain (see CLAUDE.md).
  Napi::Value SetPermission(const Napi::CallbackInfo& info, BOOL granted) {
    id device = device_;
    NSString* service = @(info[0].As<Napi::String>().Utf8Value().c_str());
    NSString* bundleId = @(info[1].As<Napi::String>().Utf8Value().c_str());
    return RunAsyncVoid(info.Env(), [device, service, bundleId, granted]() {
      NSError* error = nil;
      NSString* dataPath = coresim::DeviceDataPath(device);
      ThrowIfFailed(coresim::SetTCCAccess(dataPath, service, bundleId, granted, &error), error);
    });
  }

  Napi::Value ResetPermission(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* service = @(info[0].As<Napi::String>().Utf8Value().c_str());
    NSString* bundleId = @(info[1].As<Napi::String>().Utf8Value().c_str());
    return RunAsyncVoid(info.Env(), [device, service, bundleId]() {
      NSError* error = nil;
      NSString* dataPath = coresim::DeviceDataPath(device);
      ThrowIfFailed(coresim::ResetTCCAccess(dataPath, service, bundleId, &error), error);
    });
  }

  // Reads directly from the same TCC.db SetPermission/ResetPermission write to — no
  // CoreSimulator getter for privacy-access state exists (see tcc_privacy.h).
  Napi::Value GetPermission(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* service = @(info[0].As<Napi::String>().Utf8Value().c_str());
    NSString* bundleId = @(info[1].As<Napi::String>().Utf8Value().c_str());
    return RunAsync<TCCAuthStatus>(
        info.Env(),
        [device, service, bundleId]() -> TCCAuthStatus {
          NSError* error = nil;
          TCCAuthStatus status = kTCCAuthNotDetermined;
          NSString* dataPath = coresim::DeviceDataPath(device);
          ThrowIfFailed(coresim::GetTCCAccess(dataPath, service, bundleId, &status, &error), error);
          return status;
        },
        [](Napi::Env env, TCCAuthStatus status) -> Napi::Value {
          return Napi::String::New(env, TCCAuthStatusToString(status));
        });
  }

  Napi::Value DarwinNotificationGetState(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* name = @(info[0].As<Napi::String>().Utf8Value().c_str());
    return RunAsync<unsigned long long>(
        info.Env(),
        [device, name]() -> unsigned long long {
          unsigned long long state = 0;
          NSError* error = nil;
          ThrowIfFailed(coresim::DarwinNotificationGetState(device, &state, name, &error), error);
          return state;
        },
        // A JS `number` (double) only has 53 bits of integer precision — this state is a full
        // 64-bit value any process can stuff an arbitrary counter or bit field into (see
        // commands/darwin-notification.ts), so it's exposed as a bigint instead, via the matching
        // Node-API uint64 conversion, rather than silently rounding it on the way out.
        [](Napi::Env env, unsigned long long state) -> Napi::Value { return Napi::BigInt::New(env, state); });
  }

  Napi::Value DarwinNotificationSetState(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* name = @(info[0].As<Napi::String>().Utf8Value().c_str());
    bool lossless = false;
    unsigned long long state = info[1].As<Napi::BigInt>().Uint64Value(&lossless);
    // Checked inside the async lambda (not thrown synchronously here) so an out-of-range bigint
    // rejects the returned promise like every other failure this method can have, instead of
    // throwing synchronously and behaving inconsistently with the rest of the async API surface.
    return RunAsyncVoid(info.Env(), [device, name, state, lossless]() {
      if (!lossless) {
        throw std::invalid_argument("state must fit in an unsigned 64-bit integer (0 to 2^64-1)");
      }
      NSError* error = nil;
      ThrowIfFailed(coresim::DarwinNotificationSetState(device, state, name, &error), error);
    });
  }

  Napi::Value PostDarwinNotification(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* name = @(info[0].As<Napi::String>().Utf8Value().c_str());
    return RunAsyncVoid(info.Env(), [device, name]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::PostDarwinNotification(device, name, &error), error);
    });
  }

  Napi::Value AddMedia(const Napi::CallbackInfo& info) {
    id device = device_;
    Napi::Array paths = info[0].As<Napi::Array>();
    NSMutableArray<NSURL*>* fileURLs = [NSMutableArray arrayWithCapacity:paths.Length()];
    for (uint32_t i = 0; i < paths.Length(); i++) {
      Napi::Value path = paths.Get(i);
      [fileURLs addObject:[NSURL fileURLWithPath:@(path.As<Napi::String>().Utf8Value().c_str())]];
    }
    return RunAsyncVoid(info.Env(), [device, fileURLs]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::AddMedia(device, fileURLs, &error), error);
    });
  }

  Napi::Value AddPhoto(const Napi::CallbackInfo& info) {
    id device = device_;
    NSURL* url = [NSURL fileURLWithPath:@(info[0].As<Napi::String>().Utf8Value().c_str())];
    return RunAsyncVoid(info.Env(), [device, url]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::AddPhoto(device, url, &error), error);
    });
  }

  Napi::Value AddVideo(const Napi::CallbackInfo& info) {
    id device = device_;
    NSURL* url = [NSURL fileURLWithPath:@(info[0].As<Napi::String>().Utf8Value().c_str())];
    return RunAsyncVoid(info.Env(), [device, url]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::AddVideo(device, url, &error), error);
    });
  }

  Napi::Value GetPasteboard(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsync<NSString*>(
        info.Env(),
        [device]() -> NSString* {
          NSError* error = nil;
          NSString* result = coresim::PullPasteboardString(device, &error);
          ThrowIfFailed(result != nil, error);
          return result;
        },
        [](Napi::Env env, NSString* result) -> Napi::Value {
          return Napi::String::New(env, result ? result.UTF8String : "");
        });
  }

  Napi::Value SetPasteboard(const Napi::CallbackInfo& info) {
    id device = device_;
    NSString* content = @(info[0].As<Napi::String>().Utf8Value().c_str());
    return RunAsyncVoid(info.Env(), [device, content]() {
      NSError* error = nil;
      ThrowIfFailed(coresim::PushPasteboardString(device, content, &error), error);
    });
  }

  // `format`/`displayId`/`quality` are this addon's own options, not a CoreSimulator options
  // dictionary — the TS layer (commands/screenshot.ts) already constrains `format` to
  // 'png'/'jpeg' and `quality` to a finite 0-100, so anything else (including absent) is just
  // defaulted here rather than validated again.
  Napi::Value Screenshot(const Napi::CallbackInfo& info) {
    id device = device_;
    coresim::ScreenshotFormat format = coresim::ScreenshotFormat::kPNG;
    NSString* displayId = nil;
    NSNumber* jpegQualityPercent = nil;
    if (info.Length() > 0 && info[0].IsObject()) {
      Napi::Object options = info[0].As<Napi::Object>();
      if (options.Has("format") && options.Get("format").IsString() &&
          options.Get("format").As<Napi::String>().Utf8Value() == "jpeg") {
        format = coresim::ScreenshotFormat::kJPEG;
      }
      if (options.Has("displayId") && options.Get("displayId").IsString()) {
        displayId = @(options.Get("displayId").As<Napi::String>().Utf8Value().c_str());
      }
      if (options.Has("quality") && options.Get("quality").IsNumber()) {
        jpegQualityPercent = @(options.Get("quality").As<Napi::Number>().DoubleValue());
      }
    }
    return RunAsync<NSData*>(
        info.Env(),
        [device, displayId, format, jpegQualityPercent]() -> NSData* {
          NSError* error = nil;
          NSData* result = coresim::CaptureScreenshot(device, displayId, format, jpegQualityPercent, &error);
          ThrowIfFailed(result != nil, error);
          return result;
        },
        [](Napi::Env env, NSData* result) -> Napi::Value {
          return Napi::Buffer<uint8_t>::Copy(env, static_cast<const uint8_t*>(result.bytes), result.length);
        });
  }

  Napi::Value GetDisplays(const Napi::CallbackInfo& info) {
    id device = device_;
    return RunAsync<NSArray*>(
        info.Env(),
        [device]() -> NSArray* {
          NSError* error = nil;
          NSArray* result = coresim::ListDisplays(device, &error);
          ThrowIfFailed(result != nil, error);
          return result;
        },
        [](Napi::Env env, NSArray* result) -> Napi::Value { return NSObjectToJsValue(env, result); });
  }

  // Option dictionary keys for `spawnWithPath:options:...` aren't part of the ObjC runtime
  // metadata this addon resolves selectors from (they're string literals inside CoreSimulator's
  // own implementation) — confirmed by resolving each `SimDeviceSpawnKey*` symbol at runtime via
  // `dlsym` against the already-loaded framework (see CLAUDE.md).
  // `stdout`/`stderr` are always set here, internally, to a pipe we own — never passed through
  // from `options` (SpawnOptions, src/types.ts, deliberately has no such keys: a wrong value type
  // there crashes the whole process uncatchably, see CLAUDE.md).
  Napi::Value Spawn(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    id device = device_;
    NSString* path = @(info[0].As<Napi::String>().Utf8Value().c_str());
    NSDictionary* userOptions = OptionsArg(info, 1);
    Napi::Function onExit = info[2].As<Napi::Function>();

    // Must be constructed on the main thread; released exactly once — either below (if the spawn
    // call never actually starts a process) or inside terminationHandler once CoreSimulator
    // invokes it (which it does exactly once per successfully spawned process).
    Napi::ThreadSafeFunction exitTsfn = Napi::ThreadSafeFunction::New(env, onExit, "coresim spawn exit", 0, 1);

    return RunAsync<SpawnResult>(
        env,
        [device, path, userOptions, exitTsfn]() -> SpawnResult {
          // NSFileHandle wrapping a pipe's write end is a confirmed-safe value for stdout/stderr
          // (see CLAUDE.md) — verified empirically against a live simulator, including that our
          // own copy of the write end must be closed right after spawning (below) for EOF to ever
          // reach the read end once the child exits.
          NSPipe* stdoutPipe = [NSPipe pipe];
          NSPipe* stderrPipe = [NSPipe pipe];

          // dup() the read ends — and check both results — before ever starting the process, so a
          // descriptor-table exhaustion (EMFILE) is reported as a normal catchable error instead of
          // either leaving an untracked spawned process behind or handing JS an fd of -1 (which
          // would only surface later, as an opaque failure to wrap it in a net.Socket). The dup()'d
          // fds must outlive these NSFileHandle/NSPipe objects' own ARC lifetime, which would
          // otherwise close the original fd out from under Node once nothing in this function
          // references them anymore (verified empirically necessary).
          int stdoutFd = dup(stdoutPipe.fileHandleForReading.fileDescriptor);
          if (stdoutFd < 0) {
            int savedErrno = errno;
            // No process has started at this point, so terminationHandler (the only other place
            // that releases exitTsfn) will never run — release it here too, or the still-referenced
            // ThreadSafeFunction keeps Node's event loop alive after the caller handles the
            // rejection.
            exitTsfn.Release();
            throw NSErrorException(MakeDescriptorError(@"stdout", savedErrno));
          }
          int stderrFd = dup(stderrPipe.fileHandleForReading.fileDescriptor);
          if (stderrFd < 0) {
            int savedErrno = errno;
            close(stdoutFd);
            exitTsfn.Release();
            throw NSErrorException(MakeDescriptorError(@"stderr", savedErrno));
          }

          NSMutableDictionary* options = [userOptions mutableCopy];
          options[@"stdout"] = stdoutPipe.fileHandleForWriting;
          options[@"stderr"] = stderrPipe.fileHandleForWriting;

          void (^terminationHandler)(int) = ^(int status) {
            // Confirmed empirically (see CLAUDE.md): `status` is a raw wait(2)-style status, not a
            // plain exit code — a normal exit(127) arrived here as 32512 (127 << 8), and a
            // SIGTERM kill arrived as the bare signal number 15. Decode to Node child_process-
            // style (code, signal), exactly one of which is set.
            exitTsfn.BlockingCall([status](Napi::Env env, Napi::Function jsCallback) {
              Napi::Value code = env.Null();
              Napi::Value signal = env.Null();
              if (WIFEXITED(status)) {
                code = Napi::Number::New(env, WEXITSTATUS(status));
              } else if (WIFSIGNALED(status)) {
                signal = Napi::Number::New(env, WTERMSIG(status));
              }
              jsCallback.Call({code, signal});
            });
            exitTsfn.Release();
          };

          NSError* error = nil;
          int pid;
          try {
            pid = coresim::Spawn(device, path, options, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                                 terminationHandler, &error);
          } catch (...) {
            [stdoutPipe.fileHandleForWriting closeFile];
            [stderrPipe.fileHandleForWriting closeFile];
            close(stdoutFd);
            close(stderrFd);
            exitTsfn.Release();
            throw;
          }
          // Our own copies of the write ends must close regardless of outcome: on failure, so
          // they don't dangle open in this process; on success, so EOF ever reaches the read ends
          // once the child (the only remaining writer) exits.
          [stdoutPipe.fileHandleForWriting closeFile];
          [stderrPipe.fileHandleForWriting closeFile];
          if (pid <= 0) {
            // terminationHandler will never fire for a process that never started.
            exitTsfn.Release();
            close(stdoutFd);
            close(stderrFd);
          }
          ThrowIfFailed(pid > 0, error);

          SpawnResult result;
          result.pid = pid;
          result.stdoutFd = stdoutFd;
          result.stderrFd = stderrFd;
          return result;
        },
        [](Napi::Env env, SpawnResult result) -> Napi::Value {
          Napi::Object obj = Napi::Object::New(env);
          obj.Set("pid", result.pid);
          obj.Set("stdoutFd", result.stdoutFd);
          obj.Set("stderrFd", result.stderrFd);
          return obj;
        });
  }
};

NativeDevice::NativeDevice(const Napi::CallbackInfo& info) : Napi::ObjectWrap<NativeDevice>(info) {
  device_ = UnwrapExternalId(info);
}

void NativeDevice::Init(Napi::Env env) {
  Napi::Function ctor =
      DefineClass(env, "NativeDevice",
                  {
                      InstanceMethod<&NativeDevice::Udid>("udid"),
                      InstanceMethod<&NativeDevice::Name>("name"),
                      InstanceMethod<&NativeDevice::State>("state"),
                      InstanceMethod<&NativeDevice::DeviceTypeIdentifier>("deviceTypeIdentifier"),
                      InstanceMethod<&NativeDevice::RuntimeIdentifier>("runtimeIdentifier"),
                      InstanceMethod<&NativeDevice::Boot>("boot"),
                      InstanceMethod<&NativeDevice::GetBootStatus>("getBootStatus"),
                      InstanceMethod<&NativeDevice::Shutdown>("shutdown"),
                      InstanceMethod<&NativeDevice::Erase>("erase"),
                      InstanceMethod<&NativeDevice::Getenv>("getenv"),
                      InstanceMethod<&NativeDevice::InstallApp>("installApp"),
                      InstanceMethod<&NativeDevice::UninstallApp>("uninstallApp"),
                      InstanceMethod<&NativeDevice::LaunchApp>("launchApp"),
                      InstanceMethod<&NativeDevice::TerminateApp>("terminateApp"),
                      InstanceMethod<&NativeDevice::PropertiesOfApplication>("propertiesOfApplication"),
                      InstanceMethod<&NativeDevice::InstalledApps>("installedApps"),
                      InstanceMethod<&NativeDevice::OpenUrl>("openUrl"),
                      InstanceMethod<&NativeDevice::SetLocation>("setLocation"),
                      InstanceMethod<&NativeDevice::SendPushNotification>("sendPushNotification"),
                      InstanceMethod<&NativeDevice::AddCertificate>("addCertificate"),
                      InstanceMethod<&NativeDevice::ResetKeychain>("resetKeychain"),
                      InstanceMethod<&NativeDevice::GetUIAppearance>("getUIAppearance"),
                      InstanceMethod<&NativeDevice::SetUIAppearance>("setUIAppearance"),
                      InstanceMethod<&NativeDevice::GetIncreaseContrast>("getIncreaseContrast"),
                      InstanceMethod<&NativeDevice::SetIncreaseContrast>("setIncreaseContrast"),
                      InstanceMethod<&NativeDevice::GetContentSize>("getContentSize"),
                      InstanceMethod<&NativeDevice::SetContentSize>("setContentSize"),
                      InstanceMethod<&NativeDevice::GrantPermission>("grantPermission"),
                      InstanceMethod<&NativeDevice::RevokePermission>("revokePermission"),
                      InstanceMethod<&NativeDevice::ResetPermission>("resetPermission"),
                      InstanceMethod<&NativeDevice::GetPermission>("getPermission"),
                      InstanceMethod<&NativeDevice::DarwinNotificationGetState>("darwinNotificationGetState"),
                      InstanceMethod<&NativeDevice::DarwinNotificationSetState>("darwinNotificationSetState"),
                      InstanceMethod<&NativeDevice::PostDarwinNotification>("postDarwinNotification"),
                      InstanceMethod<&NativeDevice::AddMedia>("addMedia"),
                      InstanceMethod<&NativeDevice::AddPhoto>("addPhoto"),
                      InstanceMethod<&NativeDevice::AddVideo>("addVideo"),
                      InstanceMethod<&NativeDevice::GetPasteboard>("getPasteboard"),
                      InstanceMethod<&NativeDevice::SetPasteboard>("setPasteboard"),
                      InstanceMethod<&NativeDevice::Screenshot>("screenshot"),
                      InstanceMethod<&NativeDevice::GetDisplays>("getDisplays"),
                      InstanceMethod<&NativeDevice::Spawn>("spawn"),
                  });
  env.GetInstanceData<AddonInstanceData>()->deviceConstructor = Napi::Persistent(ctor);
}

Napi::Object NativeDevice::NewInstance(Napi::Env env, id device) {
  return WrapExternalId(env, env.GetInstanceData<AddonInstanceData>()->deviceConstructor, device);
}

class NativeDeviceSet : public Napi::ObjectWrap<NativeDeviceSet> {
 public:
  static void Init(Napi::Env env);
  static Napi::Object NewInstance(Napi::Env env, id deviceSet, id serviceContext);
  explicit NativeDeviceSet(const Napi::CallbackInfo& info);

 private:
  id deviceSet_;
  id serviceContext_;

  Napi::Value GetDevices(const Napi::CallbackInfo& info) {
    id deviceSet = deviceSet_;
    return RunAsync<NSArray*>(
        info.Env(), [deviceSet]() -> NSArray* { return Devices(deviceSet); },
        [](Napi::Env env, NSArray* devices) -> Napi::Value {
          Napi::Array result = Napi::Array::New(env, devices.count);
          for (NSUInteger i = 0; i < devices.count; i++) {
            result[static_cast<uint32_t>(i)] = NativeDevice::NewInstance(env, devices[i]);
          }
          return result;
        });
  }

  Napi::Value CreateDeviceMethod(const Napi::CallbackInfo& info) {
    id deviceSet = deviceSet_;
    id serviceContext = serviceContext_;
    NSString* typeId = @(info[0].As<Napi::String>().Utf8Value().c_str());
    NSString* runtimeId = @(info[1].As<Napi::String>().Utf8Value().c_str());
    NSString* name = @(info[2].As<Napi::String>().Utf8Value().c_str());
    return RunAsync<id>(
        info.Env(),
        [deviceSet, serviceContext, typeId, runtimeId, name]() -> id {
          id deviceType = SupportedDeviceTypesByIdentifier(serviceContext)[typeId];
          id runtime = SupportedRuntimesByIdentifier(serviceContext)[runtimeId];
          if (deviceType == nil) {
            throw std::invalid_argument("Unknown device type identifier: " + std::string(typeId.UTF8String));
          }
          if (runtime == nil) {
            throw std::invalid_argument("Unknown runtime identifier: " + std::string(runtimeId.UTF8String));
          }
          NSError* error = nil;
          id device = CreateDevice(deviceSet, deviceType, runtime, name, &error);
          ThrowIfFailed(device != nil, error);
          return device;
        },
        [](Napi::Env env, id device) -> Napi::Value { return NativeDevice::NewInstance(env, device); });
  }

  Napi::Value DeleteDeviceMethod(const Napi::CallbackInfo& info) {
    id deviceSet = deviceSet_;
    // Napi::ObjectWrap::Unwrap must run on the main thread, so this stays outside the work lambda.
    NativeDevice* device = Napi::ObjectWrap<NativeDevice>::Unwrap(info[0].As<Napi::Object>());
    id rawDevice = device->device_;
    return RunAsyncVoid(info.Env(), [deviceSet, rawDevice]() {
      NSError* error = nil;
      ThrowIfFailed(DeleteDevice(deviceSet, rawDevice, &error), error);
    });
  }
};

NativeDeviceSet::NativeDeviceSet(const Napi::CallbackInfo& info) : Napi::ObjectWrap<NativeDeviceSet>(info) {
  deviceSet_ = UnwrapExternalId(info);
  serviceContext_ = *static_cast<__unsafe_unretained id*>(info[1].As<Napi::External<void>>().Data());
}

void NativeDeviceSet::Init(Napi::Env env) {
  Napi::Function ctor = DefineClass(env, "NativeDeviceSet",
                                    {
                                        InstanceMethod<&NativeDeviceSet::GetDevices>("devices"),
                                        InstanceMethod<&NativeDeviceSet::CreateDeviceMethod>("createDevice"),
                                        InstanceMethod<&NativeDeviceSet::DeleteDeviceMethod>("deleteDevice"),
                                    });
  env.GetInstanceData<AddonInstanceData>()->deviceSetConstructor = Napi::Persistent(ctor);
}

Napi::Object NativeDeviceSet::NewInstance(Napi::Env env, id deviceSet, id serviceContext) {
  __unsafe_unretained id boxedDeviceSet = deviceSet;
  __unsafe_unretained id boxedServiceContext = serviceContext;
  return env.GetInstanceData<AddonInstanceData>()->deviceSetConstructor.New(
      {Napi::External<void>::New(env, &boxedDeviceSet), Napi::External<void>::New(env, &boxedServiceContext)});
}

class NativeServiceContext : public Napi::ObjectWrap<NativeServiceContext> {
 public:
  static void Init(Napi::Env env);
  static Napi::Object NewInstance(Napi::Env env, id serviceContext);
  explicit NativeServiceContext(const Napi::CallbackInfo& info);

 private:
  id serviceContext_;

  Napi::Value DefaultDeviceSetMethod(const Napi::CallbackInfo& info) {
    id serviceContext = serviceContext_;
    return RunAsync<id>(
        info.Env(),
        [serviceContext]() -> id {
          NSError* error = nil;
          id deviceSet = DefaultDeviceSet(serviceContext, &error);
          ThrowIfFailed(deviceSet != nil, error);
          return deviceSet;
        },
        [serviceContext](Napi::Env env, id deviceSet) -> Napi::Value {
          return NativeDeviceSet::NewInstance(env, deviceSet, serviceContext);
        });
  }

  Napi::Value SupportedDeviceTypesMethod(const Napi::CallbackInfo& info) {
    id serviceContext = serviceContext_;
    return RunAsync<std::vector<DeviceTypeEntry>>(
        info.Env(),
        [serviceContext]() -> std::vector<DeviceTypeEntry> {
          NSArray* types = coresim::SupportedDeviceTypes(serviceContext);
          std::vector<DeviceTypeEntry> result;
          result.reserve(types.count);
          for (NSUInteger i = 0; i < types.count; i++) {
            result.push_back({DeviceTypeIdentifier(types[i]).UTF8String, DeviceTypeName(types[i]).UTF8String});
          }
          return result;
        },
        [](Napi::Env env, std::vector<DeviceTypeEntry> types) -> Napi::Value {
          Napi::Array result = Napi::Array::New(env, types.size());
          for (size_t i = 0; i < types.size(); i++) {
            Napi::Object entry = Napi::Object::New(env);
            entry.Set("identifier", types[i].identifier);
            entry.Set("name", types[i].name);
            result[static_cast<uint32_t>(i)] = entry;
          }
          return result;
        });
  }

  Napi::Value SupportedRuntimesMethod(const Napi::CallbackInfo& info) {
    id serviceContext = serviceContext_;
    return RunAsync<std::vector<RuntimeEntry>>(
        info.Env(),
        [serviceContext]() -> std::vector<RuntimeEntry> {
          NSArray* runtimes = coresim::SupportedRuntimes(serviceContext);
          std::vector<RuntimeEntry> result;
          result.reserve(runtimes.count);
          for (NSUInteger i = 0; i < runtimes.count; i++) {
            result.push_back({RuntimeIdentifier(runtimes[i]).UTF8String, RuntimeName(runtimes[i]).UTF8String,
                              RuntimeVersionString(runtimes[i]).UTF8String});
          }
          return result;
        },
        [](Napi::Env env, std::vector<RuntimeEntry> runtimes) -> Napi::Value {
          Napi::Array result = Napi::Array::New(env, runtimes.size());
          for (size_t i = 0; i < runtimes.size(); i++) {
            Napi::Object entry = Napi::Object::New(env);
            entry.Set("identifier", runtimes[i].identifier);
            entry.Set("name", runtimes[i].name);
            entry.Set("versionString", runtimes[i].versionString);
            result[static_cast<uint32_t>(i)] = entry;
          }
          return result;
        });
  }
};

NativeServiceContext::NativeServiceContext(const Napi::CallbackInfo& info)
    : Napi::ObjectWrap<NativeServiceContext>(info) {
  serviceContext_ = UnwrapExternalId(info);
}

void NativeServiceContext::Init(Napi::Env env) {
  Napi::Function ctor =
      DefineClass(env, "NativeServiceContext",
                  {
                      InstanceMethod<&NativeServiceContext::DefaultDeviceSetMethod>("defaultDeviceSet"),
                      InstanceMethod<&NativeServiceContext::SupportedDeviceTypesMethod>("supportedDeviceTypes"),
                      InstanceMethod<&NativeServiceContext::SupportedRuntimesMethod>("supportedRuntimes"),
                  });
  env.GetInstanceData<AddonInstanceData>()->serviceContextConstructor = Napi::Persistent(ctor);
}

Napi::Object NativeServiceContext::NewInstance(Napi::Env env, id serviceContext) {
  return WrapExternalId(env, env.GetInstanceData<AddonInstanceData>()->serviceContextConstructor, serviceContext);
}

Napi::Value SharedServiceContextBinding(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  NSString* developerDir = @(info[0].As<Napi::String>().Utf8Value().c_str());
  return RunAsync<id>(
      env,
      [developerDir]() -> id {
        NSError* error = nil;
        id context = SharedServiceContext(developerDir, &error);
        ThrowIfFailed(context != nil, error);
        return context;
      },
      [](Napi::Env env, id context) -> Napi::Value { return NativeServiceContext::NewInstance(env, context); });
}

Napi::Value FrameworkVersionBinding(const Napi::CallbackInfo& info) {
  return RunAsync<std::string>(
      info.Env(), []() -> std::string { return CoreSimulatorFrameworkVersion(); },
      [](Napi::Env env, std::string version) -> Napi::Value { return Napi::String::New(env, version); });
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  // Runs once per Environment (see AddonInstanceData above) — never shared across a
  // worker_threads instance also `require()`-ing this addon.
  env.SetInstanceData(new AddonInstanceData());
  NativeDevice::Init(env);
  NativeDeviceSet::Init(env);
  NativeServiceContext::Init(env);
  exports.Set("sharedServiceContext", Napi::Function::New(env, SharedServiceContextBinding));
  exports.Set("frameworkVersion", Napi::Function::New(env, FrameworkVersionBinding));
  return exports;
}

}  // namespace coresim

namespace {
Napi::Object InitCoreSimModule(Napi::Env env, Napi::Object exports) { return coresim::Init(env, exports); }
}  // namespace

NODE_API_MODULE(coresim, InitCoreSimModule)
