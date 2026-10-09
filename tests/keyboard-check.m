#import <AppKit/AppKit.h>
#import <Virtualization/Virtualization.h>

// Feed events only into this process's window, never the host event queue.
@interface TestKeyboardView : NSView
@property(nonatomic, strong) id virtualMachine;
@property(nonatomic, strong) NSMutableArray<NSEvent *> *events;
@end
@implementation TestKeyboardView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event { [self.events addObject:event]; }
- (void)keyUp:(NSEvent *)event { [self.events addObject:event]; }
- (void)flagsChanged:(NSEvent *)event { [self.events addObject:event]; }
@end
#define VZVirtualMachineView TestKeyboardView
#import "../lib/display/Display.m"

static void check(BOOL value, NSString *label) {
  if (!value) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); }
  printf("PASS: %s\n", label.UTF8String);
}
static NSEvent *event(NSEventType type, unsigned short code, NSString *characters,
                      NSEventModifierFlags flags) {
  return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags
      timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
      context:nil characters:characters charactersIgnoringModifiers:characters
      isARepeat:NO keyCode:code];
}
static void deliver(NSEvent *input) {
  [NSApp postEvent:input atStart:NO];
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.05];
  while (end.timeIntervalSinceNow > 0) {
    NSEvent *pending = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:end
        inMode:NSDefaultRunLoopMode dequeue:YES];
    if (pending) [NSApp sendEvent:pending];
  }
}
int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:NO block:^(NSTimer *timer) {
      SMDisplayInitialize((VZVirtualMachine *)(id)[NSObject new]);
      SMDisplayCommand(@{@"op":@"show"}, ^(NSDictionary *result) {});
      NSDate *ready = [NSDate dateWithTimeIntervalSinceNow:0.5];
      while (ready.timeIntervalSinceNow > 0) {
        NSEvent *pending = [NSApp nextEventMatchingMask:NSEventMaskAny
            untilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]
            inMode:NSDefaultRunLoopMode dequeue:YES];
        if (pending) [NSApp sendEvent:pending];
      }
      view.events = [NSMutableArray array];
      check(window.firstResponder == view, @"guest view owns keyboard focus");
      NSArray *characters = @[@",", @"c", @"v", @"a", @"q", @"w", @"z"];
      NSArray *codes = @[@43, @8, @9, @0, @12, @13, @6];
      for (NSUInteger i = 0; i < codes.count; i++) {
        [view.events removeAllObjects];
        deliver(event(NSEventTypeKeyDown, [codes[i] unsignedShortValue], characters[i], NSEventModifierFlagCommand));
        deliver(event(NSEventTypeKeyUp, [codes[i] unsignedShortValue], characters[i], NSEventModifierFlagCommand));
        check(view.events.count == 2 && view.events[0].type == NSEventTypeKeyDown &&
              view.events[1].type == NSEventTypeKeyUp &&
              view.events[0].modifierFlags == NSEventModifierFlagCommand,
              [NSString stringWithFormat:@"Command-%@ reaches guest exactly once in both directions", characters[i]]);
      }
      [view.events removeAllObjects];
      NSEvent *shifted = event(NSEventTypeKeyDown, 6, @"z", NSEventModifierFlagCommand | NSEventModifierFlagShift);
      deliver(shifted);
      check(view.events.count == 1 && view.events[0].modifierFlags == shifted.modifierFlags,
            @"combined modifiers are preserved");
      [view.events removeAllObjects];
      deliver(event(NSEventTypeKeyDown, 0, @"a", 0));
      deliver(event(NSEventTypeKeyUp, 0, @"a", 0));
      check(view.events.count == 2, @"ordinary typing is not duplicated");
      [window makeFirstResponder:window];
      [view.events removeAllObjects];
      deliver(event(NSEventTypeKeyDown, 43, @",", NSEventModifierFlagCommand));
      check(view.events.count == 0, @"unfocused guest receives no Command shortcut");
      [window makeFirstResponder:view];
      SMDisplayCommand(@{@"op":@"hide"}, ^(NSDictionary *result) {});
      check(forwardGuestShortcut(event(NSEventTypeKeyDown, 43, @",", NSEventModifierFlagCommand)) != nil,
            @"hidden guest does not handle shortcuts");
      puts("Keyboard routing checks passed.");
      exit(0);
    }];
    [NSApp run];
  }
}
