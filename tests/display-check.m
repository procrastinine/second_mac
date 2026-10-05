#import <AppKit/AppKit.h>
#import <Virtualization/Virtualization.h>

// Exercise the production window/capture lifecycle without a VM or private
// input APIs. ScreenCaptureKit can capture only this process's test window.
@interface TestDisplayView : NSView
@property(nonatomic, strong) id virtualMachine;
@end
@implementation TestDisplayView
- (void)drawRect:(NSRect)rect {
  [NSColor.systemBlueColor setFill];
  NSRectFill(self.bounds);
  [@"Second Mac display test" drawAtPoint:NSMakePoint(30, 30) withAttributes:nil];
}
@end
#define VZVirtualMachineView TestDisplayView
#import "../lib/display/Display.m"

static void check(BOOL value, NSString *label) {
  if (!value) {
    fprintf(stderr, "FAIL: %s\n", label.UTF8String);
    exit(1);
  }
  printf("PASS: %s\n", label.UTF8String);
}
static void pump(void) {
  NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
      untilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]
      inMode:NSDefaultRunLoopMode dequeue:YES];
  if (event) [NSApp sendEvent:event];
}
static void settle(void) {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.6];
  while (end.timeIntervalSinceNow > 0) pump();
}
static NSDictionary *command(NSString *operation) {
  __block NSDictionary *value;
  SMDisplayCommand(@{@"op":operation}, ^(NSDictionary *result) { value = result; });
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:15];
  while (!value && end.timeIntervalSinceNow > 0) pump();
  check(value && !value[@"error"], [NSString stringWithFormat:@"%@: %@", operation, value[@"error"] ?: @"OK"]);
  return value;
}
static void testDisplay(void) {
  SMDisplayInitialize((VZVirtualMachine *)(id)[NSObject new]);
  check(!view, @"initialization creates no renderer");
  command(@"show"); settle();
  check(desktopIsVisible() && view.virtualMachine, @"viewing does not require private input APIs");
  [NSApp hide:nil]; settle();
  check(NSApp.hidden && !desktopIsVisible() && !view.virtualMachine, @"AppKit Hide disconnects");
  for (int i = 0; i < 3; i++) {
    command(@"screenshot"); settle();
    check(NSApp.hidden && !view.virtualMachine && !desktopIsVisible(), @"capture preserves Hide");
  }
  [NSApp unhideWithoutActivation]; settle();
  check(desktopIsVisible() && view.virtualMachine, @"Unhide reconnects");
  [window miniaturize:nil]; settle();
  check(window.miniaturized && !view.virtualMachine && !desktopIsVisible(), @"Minimize disconnects");
  for (int i = 0; i < 3; i++) {
    command(@"screenshot"); settle();
    check(window.miniaturized && !view.virtualMachine && !desktopIsVisible(), @"capture preserves Minimize");
  }
  [window deminiaturize:nil]; settle();
  check(desktopIsVisible() && view.virtualMachine, @"Dock restore reconnects");
  [window miniaturize:nil]; settle();
  command(@"show"); settle();
  check(desktopIsVisible() && view.virtualMachine && !window.miniaturized, @"Show restores minimized desktop");
  [window performClose:nil]; settle();
  check(!desktopVisible && !view.virtualMachine, @"Close disconnects");
  command(@"screenshot");
  check(!desktopVisible && !view.virtualMachine && !window.visible, @"capture leaves closed viewer closed");
}
int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:NO block:^(NSTimer *timer) {
      testDisplay();
      puts("Display lifecycle checks passed.");
      exit(0);
    }];
    [NSApp run];
  }
}
