// Turns the simulator's hardware-keyboard simulation on/off (what DeviceHub's menu item does), via CoreSimulator.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: hwkb <udid> on|off\n"); return 2; }
    dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
    NSError *err = nil;
    id ctx = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(NSClassFromString(@"SimServiceContext"), NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), @"/Applications/Xcode.app/Contents/Developer", &err);
    id set = ((id(*)(id, SEL, NSError **))objc_msgSend)(ctx, NSSelectorFromString(@"defaultDeviceSetWithError:"), &err);
    NSDictionary *byUDID = ((id(*)(id, SEL))objc_msgSend)(set, NSSelectorFromString(@"devicesByUDID"));
    id dev = byUDID[[[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:argv[1]]]];
    if (!dev) { fprintf(stderr, "no device\n"); return 1; }
    BOOL ok = ((BOOL(*)(id, SEL, BOOL, unsigned int, NSError **))objc_msgSend)(dev, NSSelectorFromString(@"setHardwareKeyboardEnabled:keyboardType:error:"), strcmp(argv[2], "on") == 0, 0, &err);
    printf("ok=%d err=%s\n", ok, err ? err.description.UTF8String : "nil");
  }
  return 0;
}
