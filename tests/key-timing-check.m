#import <AppKit/AppKit.h>
#import "../lib/display/Keyboard.h"
#import <unistd.h>

static void check(BOOL value, NSString *label) {
  if (!value) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); }
}
static double now(void) { return NSProcessInfo.processInfo.systemUptime; }
static void pump(double seconds) {
  double end = now() + seconds;
  do { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false); } while (now() < end);
}
static void polling(NSInteger fps, double phase, BOOL legacy) {
  __block BOOL held = NO, done = NO;
  __block NSInteger presses = 0, releases = 0, sampledHeld = 0;
  __block double downAt = 0, upAt = 0;
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(phase / fps * NSEC_PER_SEC)), NSEC_PER_SEC / fps, 0);
  dispatch_source_set_event_handler(timer, ^{ if (held) sampledHeld++; });
  dispatch_resume(timer);
  void (^send)(unsigned short, BOOL) = ^(unsigned short code, BOOL down) {
    held = down;
    if (down) { presses++; downAt = now(); } else { releases++; upAt = now(); }
  };
  if (legacy) { send(0, YES); send(0, NO); done = YES; }
  else SMPressKey(0, 0, SMKeyDefaultHoldMS, send, ^(BOOL success) { check(success, @"press succeeds"); done = YES; });
  double deadline = now() + 2;
  while (!done && now() < deadline) pump(0.002);
  pump(1.0 / fps);
  dispatch_source_cancel(timer);
  check(done && presses == 1 && releases == 1 && !held, @"event receiver sees one complete tap");
  if (legacy) check(sampledHeld == 0, @"regression: back-to-back tap is invisible to polling");
  else {
    check(upAt - downAt >= 0.079, @"default key stays down at least 80 ms");
    check(sampledHeld > 0, [NSString stringWithFormat:@"%ld Hz poll observes held state", (long)fps]);
  }
}
static void faults(BOOL duringDown, BOOL persistent) {
  NSMutableIndexSet *held = [NSMutableIndexSet indexSet];
  NSMutableArray *order = [NSMutableArray array];
  __block BOOL done = NO, failedOnce = NO;
  __block NSInteger completions = 0, upAttempts = 0;
  SMPressKey(0, NSEventModifierFlagCommand | NSEventModifierFlagShift, 80,
    ^(unsigned short code, BOOL down) {
      [order addObject:@[@(code), @(down)]];
      if (down) {
        [held addIndex:code];
        if (duringDown && code == 0) @throw [NSException exceptionWithName:@"Injected" reason:nil userInfo:nil];
      } else {
        upAttempts++;
        if (!duringDown && (persistent || (code == 0 && !failedOnce))) {
          failedOnce = YES;
          @throw [NSException exceptionWithName:@"Injected" reason:nil userInfo:nil];
        }
        [held removeIndex:code];
      }
    }, ^(BOOL success) { check(!success, @"partial delivery is never reported as success"); completions++; done = YES; });
  double deadline = now() + 2;
  while (!done && now() < deadline) pump(0.002);
  check(done && completions == 1 && !SMKeyboardBusy(), @"failure completes once and clears busy state");
  if (persistent) check(upAttempts == 6, @"permanent failure attempts and retries every release, bounded");
  else check(held.count == 0, @"failure releases the primary key and all modifiers");
  check([order[3][0] integerValue] == 0 && [order[4][0] integerValue] == 55 && [order[5][0] integerValue] == 56,
      @"cleanup releases primary key before modifiers in reverse order");
}
int main(void) {
  @autoreleasepool {
    for (NSNumber *fps in @[@30,@60,@120]) {
      for (NSNumber *phase in @[@0.25,@0.5,@0.75]) {
        polling(fps.integerValue, phase.doubleValue, YES);
        polling(fps.integerValue, phase.doubleValue, NO);
      }
    }
    puts("PASS: event delivery and held-state polling at 30/60/120 Hz; legacy timing reproduces misses");
    __block double downAt = 0, upAt = 0;
    __block BOOL done = NO;
    SMPressKey(0, 0, 250, ^(unsigned short code, BOOL down) {
      if (down) { usleep(100000); downAt = now(); }
      else upAt = now();
    }, ^(BOOL ok) { check(ok, @"delayed-send press succeeds"); done = YES; });
    check(SMKeyboardBusy() && !SMBeginKeyboardPause(), @"memory saving cannot capture a held key");
    __block BOOL secondSent = NO;
    SMPressKey(1, 0, 80, ^(unsigned short code, BOOL down) { secondSent = YES; },
        ^(BOOL ok) { check(!ok, @"overlapping key command fails"); });
    double deadline = now() + 2;
    while (!done && now() < deadline) pump(0.002);
    check(done && !secondSent && upAt - downAt >= 0.249, @"hold is measured after actual down send and overlapping commands do not interfere");
    check(SMBeginKeyboardPause(), @"memory save starts after release");
    SMPressKey(1, 0, 80, ^(unsigned short code, BOOL down) { secondSent = YES; },
        ^(BOOL ok) { check(!ok, @"pause transition blocks new input"); });
    check(!secondSent, @"no keys injected during pause transition");
    SMEndKeyboardPause();
    faults(YES, NO); faults(NO, NO); faults(NO, YES);
    for (id value in @[@0,@9,@5001,@YES,@12.5,@"80",@(NAN)]) check(!SMKeyHoldValid(value), @"invalid hold rejected");
    check(SMKeyHoldValid(@10) && SMKeyHoldValid(@80) && SMKeyHoldValid(@5000), @"valid hold bounds");
    __block BOOL held = NO;
    SMPressKey(0, 0, 80, ^(unsigned short code, BOOL down) { held = down; }, ^(BOOL ok) {});
    // No request/client object is needed to finish the press and release.
    pump(0.15);
    check(!held && !SMKeyboardBusy(), @"release outlives a caller that stops waiting");
    puts("PASS: explicit duration, delayed send, modifier cleanup, transient/permanent failures, pause guard and abandoned caller");
  }
}
