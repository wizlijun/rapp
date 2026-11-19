// Sends real HID keyboard events to a booted simulator (what idb's `ui key` does), so keys XCUITest cannot type
// (Backspace, Esc, a lone Shift, key repeat) reach the app as UIPresses.
// usage: simkey <udid> <token>...   token: a letter/digit/punct char, or BS ESC RET TAB SPACE LEFT RIGHT UP DOWN
//   PGUP PGDN SHIFT CMD, "S+x" (shift+x), "C+x" (cmd+x), "^+x" (control+x), "HOLD:<token>:<ms>", "WAIT:<ms>"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
typedef void *(*MsgFn)(uint32_t, uint32_t);
static MsgFn kb;
static id client;
static void sendRaw(uint32_t code, uint32_t dir) {
  void *m = kb(code, dir);
  dispatch_semaphore_t s = dispatch_semaphore_create(0);
  ((void (*)(id, SEL, void *, BOOL, dispatch_queue_t, void (^)(NSError *)))objc_msgSend)(
      client, NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:"), m, YES,
      dispatch_get_main_queue(), ^(NSError *e) { if (e) fprintf(stderr, "send: %s\n", e.description.UTF8String); dispatch_semaphore_signal(s); });
  while (dispatch_semaphore_wait(s, DISPATCH_TIME_NOW)) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
}
static void pause_ms(int ms) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:ms / 1000.0]]; }
static int usage(NSString *t, BOOL *shift) {
  NSDictionary *named = @{@"BS": @42, @"ESC": @41, @"RET": @40, @"TAB": @43, @"SPACE": @44, @"LEFT": @80, @"RIGHT": @79,
                          @"UP": @82, @"DOWN": @81, @"PGUP": @75, @"PGDN": @78, @"SHIFT": @225, @"CMD": @227};
  if (named[t]) return [named[t] intValue];
  if (t.length != 1) return -1;
  unichar c = [t characterAtIndex:0];
  if (c >= 'a' && c <= 'z') return 4 + c - 'a';
  if (c >= 'A' && c <= 'Z') { *shift = YES; return 4 + c - 'A'; }
  if (c >= '1' && c <= '9') return 30 + c - '1';
  if (c == '0') return 39;
  NSString *plain = @"-=[]\\;',./`", *shifted = @"_+{}|:\"<>?~";
  int codes[] = {45, 46, 47, 48, 49, 51, 52, 54, 55, 56, 53};
  for (int i = 0; i < 11; i++) {
    if (c == [plain characterAtIndex:i]) return codes[i];
    if (c == [shifted characterAtIndex:i]) { *shift = YES; return codes[i]; }
  }
  return -1;
}
static void tap(NSString *t, int holdMs) {
  uint32_t mod = 0;
  if ([t hasPrefix:@"S+"]) { mod = 225; t = [t substringFromIndex:2]; }
  if ([t hasPrefix:@"C+"]) { mod = 227; t = [t substringFromIndex:2]; }
  if ([t hasPrefix:@"^+"]) { mod = 224; t = [t substringFromIndex:2]; }
  BOOL shift = NO;
  int code = usage(t, &shift);
  if (code < 0) { fprintf(stderr, "unknown token %s\n", t.UTF8String); return; }
  if (shift) mod = 225;
  if (mod) { sendRaw(mod, 1); pause_ms(20); }
  sendRaw(code, 1);
  pause_ms(holdMs);
  sendRaw(code, 2);
  if (mod) { pause_ms(20); sendRaw(mod, 2); }
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: simkey <udid> <token>...\n"); return 2; }
    dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
    void *sk = dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW);
    kb = (MsgFn)dlsym(sk, "IndigoHIDMessageForKeyboardArbitrary");
    NSError *err = nil;
    id ctx = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(NSClassFromString(@"SimServiceContext"), NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), @"/Applications/Xcode.app/Contents/Developer", &err);
    id set = ((id(*)(id, SEL, NSError **))objc_msgSend)(ctx, NSSelectorFromString(@"defaultDeviceSetWithError:"), &err);
    id dev = ((id(*)(id, SEL))objc_msgSend)(set, NSSelectorFromString(@"devicesByUDID"))[[[NSUUID alloc] initWithUUIDString:@(argv[1])]];
    if (!dev) { fprintf(stderr, "no device\n"); return 1; }
    Class cls = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    client = ((id(*)(id, SEL, id, NSError **))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithDevice:error:"), dev, &err);
    if (!client) { fprintf(stderr, "hid client: %s\n", err.description.UTF8String); return 1; }
    for (int i = 2; i < argc; i++) {
      NSString *t = @(argv[i]);
      if ([t hasPrefix:@"WAIT:"]) { pause_ms([[t substringFromIndex:5] intValue]); continue; }
      if ([t hasPrefix:@"HOLD:"]) {
        NSArray *p = [t componentsSeparatedByString:@":"];
        tap(p[1], [p[2] intValue]);
      } else {
        tap(t, 30);
      }
      pause_ms(60);
    }
  }
  return 0;
}
