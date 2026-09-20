#include "sim_video_recording.h"

#import <objc/message.h>

#include "objc_runtime.h"
#include "safe_dispatch.h"
#include "sim_screenshot.h"

namespace coresim {

namespace {

NSString* const kVideoRecordingErrorDomain = @"com.appium.coresim.VideoRecording";

NSError* MakeError(NSInteger code, NSString* message) {
  return [NSError errorWithDomain:kVideoRecordingErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

id IdGetter(id target, const std::string& selectorName) {
  RequireSelector(target, selectorName);
  SEL selector = SelectorNamed(selectorName);
  return SafeInvoke([&] {
    using Fn = id (*)(id, SEL);
    return ((Fn)objc_msgSend)(target, selector);
  });
}

// The device-wide "capture service" port that answers these selectors — distinct from the display
// descriptor passed as `screen` below. Found by scanning ioPorts for whichever descriptor
// responds, since no protocol exists to check against (see CLAUDE.md). Throws
// NativeSimUnavailableError (not NSError**) when nothing responds — this is a version-support gap,
// not an operational failure, so it should flow through the same "unavailable" path as a missing
// selector elsewhere; the exact descriptor classes scanned are folded into the error's `detail` so
// a future CI failure on an unfamiliar Xcode/CoreSimulator pairing is diagnosable from the error
// message alone.
id ResolveVideoCaptureService(id device, NSError** error) {
  static const std::string kStartRecordingSelector =
      "startRecordingFromScreen:maskPolicy:assetWriterOutputSettings:outputFile:completionQueue:completionHandler:";
  id ioClient = IdGetter(device, "io");
  if (ioClient == nil) {
    *error = MakeError(1, @"Device has no IO client available — is it booted?");
    return nil;
  }
  NSArray* ports = IdGetter(ioClient, "ioPorts");
  SEL selector = NSSelectorFromString(@(kStartRecordingSelector.c_str()));
  NSMutableArray<NSString*>* descriptorClasses = [NSMutableArray array];
  for (id port in ports) {
    id descriptor = IdGetter(port, "descriptor");
    if (descriptor == nil) {
      continue;
    }
    if ([descriptor respondsToSelector:selector]) {
      return descriptor;
    }
    [descriptorClasses addObject:NSStringFromClass([descriptor class])];
  }
  std::string detail = CoreSimulatorFrameworkVersion() + " — scanned " + std::to_string(descriptorClasses.count) +
                       " ioPort descriptor(s): [" +
                       std::string(([descriptorClasses componentsJoinedByString:@", "] ?: @"").UTF8String) + "]";
  throw NativeSimUnavailableError("selector", kStartRecordingSelector, detail);
}

}  // namespace

BOOL StartVideoRecording(id device, NSString* displayId, VideoMaskPolicy mask, NSDictionary* assetWriterOutputSettings,
                         NSString* outputFile, dispatch_queue_t queue, void (^handler)(NSError*), NSError** error) {
  id captureService = ResolveVideoCaptureService(device, error);
  if (captureService == nil) {
    return NO;
  }
  id screen = ResolveCaptureDisplay(device, displayId, error);
  if (screen == nil) {
    return NO;
  }
  static const std::string kSelectorName =
      "startRecordingFromScreen:maskPolicy:assetWriterOutputSettings:outputFile:completionQueue:completionHandler:";
  SEL selector = NSSelectorFromString(@(kSelectorName.c_str()));
  return SafeInvoke([&] {
    using Fn = void (*)(id, SEL, id, long long, NSDictionary*, NSString*, dispatch_queue_t, void (^)(NSError*));
    ((Fn)objc_msgSend)(captureService, selector, screen, static_cast<long long>(mask), assetWriterOutputSettings,
                       outputFile, queue, handler);
    return YES;
  });
}

BOOL StopVideoRecording(id device, dispatch_queue_t queue, void (^handler)(NSError*), NSError** error) {
  id captureService = ResolveVideoCaptureService(device, error);
  if (captureService == nil) {
    return NO;
  }
  static const std::string kSelectorName = "stopRecordingWithCompletionQueue:completionHandler:";
  SEL selector = NSSelectorFromString(@(kSelectorName.c_str()));
  return SafeInvoke([&] {
    using Fn = void (*)(id, SEL, dispatch_queue_t, void (^)(NSError*));
    ((Fn)objc_msgSend)(captureService, selector, queue, handler);
    return YES;
  });
}

}  // namespace coresim
