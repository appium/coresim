#include "sim_video_recording.h"

#import <objc/message.h>

#include "objc_runtime.h"
#include "safe_dispatch.h"
#include "sim_screenshot.h"

namespace coresim {

namespace {

NSString* const kVideoRecordingErrorDomain = @"com.appium.coresim.VideoRecording";

NSError* MakeError(NSInteger code, NSString* message) {
  return [NSError errorWithDomain:kVideoRecordingErrorDomain
                              code:code
                          userInfo:@{NSLocalizedDescriptionKey : message}];
}

id IdGetter(id target, const std::string& selectorName) {
  RequireSelector(target, selectorName);
  SEL selector = SelectorNamed(selectorName);
  return SafeInvoke([&] {
    using Fn = id (*)(id, SEL);
    return ((Fn)objc_msgSend)(target, selector);
  });
}

// The one (private, headerless) `-[device io] ioPorts` descriptor that answers
// startRecordingFromScreen:.../stopRecordingWithCompletionQueue:... — a different object than the
// renderable display descriptor sim_screenshot.mm resolves (that one is the `screen` *argument*
// these selectors take, not their receiver — confirmed empirically by UUID match against a real
// `simctl io screenshot`'s reported display). There's no protocol name to
// -conformsToProtocol: against (no header exists for it — reverse-engineered from `strings` on the
// real `simctl` binary, see CLAUDE.md), so the only way to find it is to scan every port's
// descriptor for whichever one responds to the selector. Confirmed empirically to be a single,
// stable, device-wide port regardless of how many displays the device has.
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
  for (id port in ports) {
    id descriptor = IdGetter(port, "descriptor");
    if (descriptor != nil && [descriptor respondsToSelector:selector]) {
      return descriptor;
    }
  }
  *error = MakeError(2, @"No video capture service was found on this device — video recording may "
                        @"not be supported on this CoreSimulator version");
  return nil;
}

}  // namespace

BOOL StartVideoRecording(id device, NSString* displayId, VideoMaskPolicy mask,
                          NSDictionary* assetWriterOutputSettings, NSString* outputFile,
                          dispatch_queue_t queue, void (^handler)(NSError*), NSError** error) {
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
