#include "sim_screenshot.h"

#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>

#include "objc_runtime.h"
#include "safe_dispatch.h"

namespace coresim {

namespace {

NSString* const kScreenshotErrorDomain = @"com.appium.coresim.Screenshot";

NSError* MakeError(NSInteger code, NSString* message) {
  return [NSError errorWithDomain:kScreenshotErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

id IdGetter(id target, const std::string& selectorName) {
  RequireSelector(target, selectorName);
  SEL selector = SelectorNamed(selectorName);
  return SafeInvoke([&] {
    using Fn = id (*)(id, SEL);
    return ((Fn)objc_msgSend)(target, selector);
  });
}

// -[<SimDisplayDescriptorState> displayClass] — iOS's main display is class 0; tvOS renders only
// on the (non-zero) TVOut class.
unsigned short DisplayClass(id descriptorState) {
  static const std::string kSelectorName = "displayClass";
  RequireSelector(descriptorState, kSelectorName);
  SEL selector = SelectorNamed(kSelectorName);
  return SafeInvoke([&] {
    using Fn = unsigned short (*)(id, SEL);
    return ((Fn)objc_msgSend)(descriptorState, selector);
  });
}

// Finds the IO port descriptor for the device's main display among -[SimDeviceIOClient ioPorts].
// Only a port that actually renders a screen conforms to the (private, headerless)
// SimDisplayIOSurfaceRenderable/SimDisplayRenderable protocols — other ports (audio, the
// screenshot mach service itself) don't respond to either accessor below, so the
// respondsToSelector: checks are the actual filter, not defensive leftovers. Prefers displayClass
// 0 (the main display) but falls back to the first renderable display found, so a target with no
// class-0 display (e.g. tvOS) still gets a screenshot instead of an outright failure.
id FindMainDisplayDescriptor(id ioClient) {
  NSArray* ports = IdGetter(ioClient, "ioPorts");
  id fallback = nil;
  for (id port in ports) {
    id descriptor = IdGetter(port, "descriptor");
    if (descriptor == nil) continue;
    if (![descriptor respondsToSelector:NSSelectorFromString(@"framebufferSurface")] &&
        ![descriptor respondsToSelector:NSSelectorFromString(@"ioSurface")]) {
      continue;
    }
    if (![descriptor respondsToSelector:NSSelectorFromString(@"state")]) {
      continue;
    }
    id state = IdGetter(descriptor, "state");
    if (state == nil || ![state respondsToSelector:NSSelectorFromString(@"displayClass")]) {
      continue;
    }
    if (DisplayClass(state) == 0) {
      return descriptor;
    }
    if (fallback == nil) {
      fallback = descriptor;
    }
  }
  return fallback;
}

// Unlike IdGetter, doesn't RequireSelector: a display proxy that has lost its connection (e.g. the
// device just shut down) can legitimately stop responding to a selector it answered a moment ago —
// that's "no surface right now", not "unsupported on this CoreSimulator", so it must not raise
// NativeSimUnavailableError the way a genuinely missing selector should.
id OptionalIdGetter(id target, NSString* selectorName) {
  SEL selector = NSSelectorFromString(selectorName);
  if (![target respondsToSelector:selector]) {
    return nil;
  }
  return SafeInvoke([&] {
    using Fn = id (*)(id, SEL);
    return ((Fn)objc_msgSend)(target, selector);
  });
}

// `framebufferSurface` is the primary surface since Xcode 13.2 split what used to be a single
// `ioSurface`; both are real (non-optional) members of the descriptor's protocol once it's passed
// FindMainDisplayDescriptor's filter above, but the underlying remote proxy can still legitimately
// vend nil for either — or stop responding entirely if the connection just dropped — so both are
// tried before giving up.
id RenderableSurface(id descriptor) {
  return OptionalIdGetter(descriptor, @"framebufferSurface") ?: OptionalIdGetter(descriptor, @"ioSurface");
}

}  // namespace

NSData* CaptureScreenshotPNG(id device, NSError** error) {
  id ioClient = IdGetter(device, "io");
  if (ioClient == nil) {
    *error = MakeError(1, @"Device has no IO client available — is it booted?");
    return nil;
  }

  id descriptor = FindMainDisplayDescriptor(ioClient);
  if (descriptor == nil) {
    *error = MakeError(2, @"No renderable display port was found on this device");
    return nil;
  }

  id surfaceObj = RenderableSurface(descriptor);
  if (surfaceObj == nil) {
    *error = MakeError(3, @"The device's display surface is not available yet");
    return nil;
  }

  IOSurfaceRef surfaceRef = (__bridge IOSurfaceRef)surfaceObj;
  CIImage* ciImage = [CIImage imageWithIOSurface:surfaceRef];
  if (ciImage == nil) {
    *error = MakeError(4, @"Failed to wrap the device's display surface as an image");
    return nil;
  }

  // A fresh CIContext per call, matching this operation's one-shot semantics (mirrors
  // simctl's own screenshot command) rather than the persistent, reused context a
  // continuous video/streaming path would want.
  CIContext* context = [CIContext contextWithOptions:nil];
  CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
  if (cgImage == nil) {
    *error = MakeError(5, @"Failed to render the device's display surface");
    return nil;
  }

  NSMutableData* pngData = [NSMutableData data];
  CGImageDestinationRef destination =
      CGImageDestinationCreateWithData((__bridge CFMutableDataRef)pngData, CFSTR("public.png"), 1, NULL);
  if (destination == nullptr) {
    CGImageRelease(cgImage);
    *error = MakeError(6, @"Failed to create a PNG encoder for the captured screenshot");
    return nil;
  }
  CGImageDestinationAddImage(destination, cgImage, nullptr);
  BOOL ok = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGImageRelease(cgImage);
  if (!ok) {
    *error = MakeError(7, @"Failed to encode the captured screenshot as PNG");
    return nil;
  }
  return pngData;
}

}  // namespace coresim
