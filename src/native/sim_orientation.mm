#include "sim_orientation.h"

#include <unistd.h>

#include "sim_device.h"
#include "sim_service_context.h"

namespace coresim {

namespace {

// backboardd's persisted GraphicsOrientation swaps landscape left/right vs. our own
// DeviceOrientation wire values — confirmed empirically (see CLAUDE.md).
int32_t TranslateGraphicsOrientation(NSInteger graphicsOrientation) {
  switch (graphicsOrientation) {
    case 3:
      return 4;
    case 4:
      return 3;
    default:
      return static_cast<int32_t>(graphicsOrientation);
  }
}

// The current boot's live digitizer entry, or nil if never rotated this boot. New boots always
// append a fresh entry rather than reusing an old one (confirmed empirically across reboots), so
// the last array entry is always the live one.
NSNumber* CurrentGraphicsOrientation(NSData* defaultsReadOutput) {
  // Old-style ASCII plist (defaults read's own format) has no integer type — every scalar comes
  // back as NSString, not NSNumber (confirmed empirically); both respond to -integerValue.
  id plist = [NSPropertyListSerialization propertyListWithData:defaultsReadOutput
                                                       options:NSPropertyListImmutable
                                                        format:nil
                                                         error:nil];
  NSArray* entries = [plist isKindOfClass:[NSArray class]] ? (NSArray*)plist : nil;
  NSDictionary* last = [entries.lastObject isKindOfClass:[NSDictionary class]] ? entries.lastObject : nil;
  NSDictionary* props = [last[@"props"] isKindOfClass:[NSDictionary class]] ? last[@"props"] : nil;
  id value = props[@"GraphicsOrientation"];
  BOOL isScalar = [value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]];
  return isScalar ? @([value integerValue]) : nil;
}

}  // namespace

void ReadGuestOrientation(id device, void (^handler)(int32_t orientation)) {
  id runtime = DeviceRuntime(device);
  NSString* runtimeRoot = RuntimeRootPath(runtime).stringByStandardizingPath;
  NSString* defaultsPath = [runtimeRoot stringByAppendingPathComponent:@"usr/bin/defaults"];

  NSPipe* stdoutPipe = [NSPipe pipe];
  int stdoutFd = dup(stdoutPipe.fileHandleForReading.fileDescriptor);
  if (stdoutFd < 0) {
    handler(1);
    return;
  }

  NSDictionary* options = @{
    // argv[0] not auto-prepended by Spawn (see spawnProcess.ts).
    @"arguments" : @[ @"defaults", @"read", @"com.apple.backboardd", @"BKDigitizerPersistentServiceProperties" ],
    @"stdout" : @(stdoutPipe.fileHandleForWriting.fileDescriptor),
    @"stderr" : @(stdoutPipe.fileHandleForWriting.fileDescriptor),
    @"standalone" : @NO,
  };

  dispatch_queue_t queue = dispatch_queue_create("io.appium.coresim.orientationPoll", DISPATCH_QUEUE_SERIAL);
  NSError* spawnError = nil;
  int pid = 0;
  // Fire-and-forget: only stdout matters — a missing key and a spawn failure both just fall back
  // to portrait below.
  try {
    pid = Spawn(device, defaultsPath, options, queue,
                ^(int){
                },
                &spawnError);
  } catch (...) {
    pid = 0;
  }
  [stdoutPipe.fileHandleForWriting closeFile];
  if (pid <= 0) {
    close(stdoutFd);
    handler(1);
    return;
  }

  dispatch_async(queue, ^{
    NSMutableData* output = [NSMutableData data];
    uint8_t buffer[4096];
    ssize_t n;
    while ((n = read(stdoutFd, buffer, sizeof(buffer))) > 0) {
      [output appendBytes:buffer length:(NSUInteger)n];
    }
    close(stdoutFd);
    NSNumber* graphicsOrientation = CurrentGraphicsOrientation(output);
    handler(graphicsOrientation != nil ? TranslateGraphicsOrientation(graphicsOrientation.integerValue) : 1);
  });
}

}  // namespace coresim
