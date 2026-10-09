#import "Keyboard.h"
#import <AppKit/AppKit.h>

static BOOL keyboardBusy = NO;
static BOOL keyboardPausing = NO;
BOOL SMKeyboardBusy(void) { return keyboardBusy; }
BOOL SMBeginKeyboardPause(void) {
  if (keyboardBusy) return NO;
  keyboardPausing = YES;
  return YES;
}
void SMEndKeyboardPause(void) { keyboardPausing = NO; }
BOOL SMKeyHoldValid(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
      [value doubleValue] >= SMKeyMinHoldMS && [value doubleValue] <= SMKeyMaxHoldMS &&
      [value doubleValue] == [value integerValue];
}
static void releaseKeys(NSArray<NSNumber *> *keys, void (^send)(unsigned short, BOOL),
    BOOL success, BOOL retry, void (^completion)(BOOL)) {
  NSMutableArray *failed = [NSMutableArray array];
  for (NSNumber *code in keys) {
    @try { send(code.unsignedShortValue, NO); }
    @catch (NSException *exception) { [failed addObject:code]; }
  }
  if (failed.count && retry) {
    // Try a transiently failed key-up again, but always release other keys too.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      releaseKeys(failed, send, NO, NO, completion);
    });
  } else {
    keyboardBusy = NO;
    completion(success && failed.count == 0);
  }
}
void SMPressKey(unsigned short code, NSUInteger flags, NSInteger holdMS,
    void (^send)(unsigned short, BOOL), void (^completion)(BOOL)) {
  NSCAssert(NSThread.isMainThread, @"Keyboard input must run on the VM queue");
  if (keyboardBusy || keyboardPausing || !SMKeyHoldValid(@(holdMS))) { completion(NO); return; }
  keyboardBusy = YES;
  NSMutableArray<NSNumber *> *codes = [NSMutableArray array];
  if (flags & NSEventModifierFlagShift) [codes addObject:@56];
  if (flags & NSEventModifierFlagControl) [codes addObject:@59];
  if (flags & NSEventModifierFlagOption) [codes addObject:@58];
  if (flags & NSEventModifierFlagCommand) [codes addObject:@55];
  if (![codes containsObject:@(code)]) [codes addObject:@(code)];
  NSMutableArray *pressed = [NSMutableArray array];
  @try {
    for (NSNumber *key in codes) {
      // A send can fail after delivery. Include that key in cleanup as well.
      [pressed addObject:key];
      send(key.unsignedShortValue, YES);
    }
  } @catch (NSException *exception) {
    releaseKeys(pressed.reverseObjectEnumerator.allObjects, send, NO, YES, completion);
    return;
  }
  NSArray *release = pressed.reverseObjectEnumerator.allObjects;
  // Schedule from the actual down delivery, never from the request's start.
  // A busy queue may lengthen a press, but cannot collapse down/up together.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, holdMS * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    releaseKeys(release, send, YES, YES, completion);
  });
}
