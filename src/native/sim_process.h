#pragma once

#import <Foundation/Foundation.h>

namespace coresim {

// Locates the Unix-domain socket the device's `com.apple.webinspectord_sim` launchd job listens
// on, for WebKit remote-debugging tools to connect to. No ObjC dispatch here (see CLAUDE.md) —
// CoreSimulator itself has no API for this; it's libproc/sysctl process introspection instead,
// the same mechanism `lsof -aUc launchd_sim` uses.
NSString* FindWebInspectorSocket(NSString* udid, NSError** error);

}  // namespace coresim
