// Guest-only hardware control, shared by Tart and the offline Recovery runner.
#import "SecondMacDisplay.h"
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Virtualization/Virtualization.h>
#import <Vision/Vision.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "Pointer.h"
#import "Keyboard.h"
@interface NSObject (VMPrivate)
- (NSArray *)_keyboards;
- (NSArray *)_pointingDevices;
- (id)initWithEvent:(NSEvent *)event view:(NSView *)view;
- (id)initWithLocation:(CGPoint)location pressedButtons:(NSInteger)buttons;
- (CGPoint)location;
- (void)sendPointerEvents:(NSArray *)events;
- (void)sendScrollWheelEvents:(NSArray *)events;
- (id)initWithScrollingDeltaX:(double)x scrollingDeltaY:(double)y
    acceleratedScrollingDeltaX:(double)ax acceleratedScrollingDeltaY:(double)ay
    scrollPhase:(NSUInteger)phase momentumPhase:(NSUInteger)momentum;

- (void)sendKeyEvents:(NSArray *)events;
- (id)initWithEvent:(NSEvent *)event;
@end
static VZVirtualMachine *vm;
static VZVirtualMachineView *view;
static NSWindow *window;
// Whether the user opened a desktop; AppKit can hide/minimize it independently.
static BOOL desktopVisible = NO;
static BOOL displayInUse = NO;
static NSWindow *captureDesktop;
static NSTimeInterval displayReadyAfter;
static void (^response)(NSDictionary *);
static void prepareDisplay(void);
static BOOL desktopIsVisible(void) {
  return desktopVisible && !NSApp.hidden && !window.miniaturized && window.visible;
}

// NSApplication treats Command combinations as menu shortcuts and can drop
// their key-up events before NSWindow receives them. This in-process monitor
// forwards both halves only while our VM view owns focus. It observes no other
// application's events and requires no host Accessibility permission.
static id shortcutMonitor;
static NSEvent *forwardGuestShortcut(NSEvent *event) {
  if (desktopIsVisible() && view.virtualMachine &&
      window.firstResponder == view && event.window == window &&
      (event.modifierFlags & NSEventModifierFlagCommand)) {
    if (event.type == NSEventTypeKeyDown) { [view keyDown:event]; return nil; }
    if (event.type == NSEventTypeKeyUp) { [view keyUp:event]; return nil; }
  }
  return event;
}

static void releaseHiddenDisplay(void) {
  if (displayInUse || desktopIsVisible() || !window)
    return;
  // Remove the framebuffer consumer, not just its visible pixels. Keeping an
  // offscreen VZVirtualMachineView attached still composites guest frames.
  // Preserve AppKit's normal Dock/minimize and Hide/Unhide behavior. Only an
  // explicit close/hide removes the desktop from the application's windows.
  if (!desktopVisible)
    [window orderOut:nil];
  view.virtualMachine = nil;
  // Retain the disconnected view/window objects for capture reuse. There is
  // no VM framebuffer consumer while virtualMachine is nil, and the window
  // is absent from the desktop instead of being parked at its edge.
}
static void finishDisplayUse(void) {
  if (captureDesktop) {
    NSWindow *temporary = window;
    [window orderOut:nil];
    view.virtualMachine = nil;
    window = captureDesktop;
    captureDesktop = nil;
    window.contentView = view;
    [temporary close];
  }
  displayInUse = NO;
  if (desktopIsVisible())
    prepareDisplay();
  else
    releaseHiddenDisplay();
}
static void reply(NSDictionary *value) {
  void (^completion)(NSDictionary *) = response;
  void (^finish)(void) = ^{
    finishDisplayUse();
    completion(value);
  };
  if (NSThread.isMainThread)
    finish();
  else
    dispatch_async(dispatch_get_main_queue(), finish);
}

static void hideDesktop(void) {
  desktopVisible = NO;
  releaseHiddenDisplay();
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

// Own the entire one-frame stream lifetime. SCScreenshotManager can still be
// tearing down its internal stream when its image callback returns; detaching
// the VM view then makes rapid subsequent captures intermittently fail.
@interface SMFrameCapture : NSObject <SCStreamOutput, SCStreamDelegate> {
  SCStream *_stream;
  CGImageRef _image;
  NSError *_error;
  BOOL _starting, _finishing, _stopping, _finished;
  void (^_completion)(CGImageRef, NSError *);
}
- (void)startWithFilter:(SCContentFilter *)filter
         configuration:(SCStreamConfiguration *)configuration
            completion:(void (^)(CGImageRef, NSError *))completion;
@end
static SMFrameCapture *activeCapture;
@implementation SMFrameCapture
- (void)complete:(NSError *)error {
  if (_finished)
    return;
  _finished = YES;
  [_stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
  _stream = nil;
  CGImageRef image = _image;
  _image = NULL;
  void (^completion)(CGImageRef, NSError *) = _completion;
  _completion = nil;
  activeCapture = nil;
  finishDisplayUse();
  // Vision can have a substantial cold start. Never block the VM's main queue
  // or keep its hidden renderer attached while recognizing a completed frame.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    completion(image, error);
    if (image)
      CGImageRelease(image);
  });
}
- (void)stopIfReady {
  if (_starting || _stopping || _finished)
    return;
  _stopping = YES;
  [_stream stopCaptureWithCompletionHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self complete:self->_error ?: error]; });
  }];
}
- (void)fail:(NSString *)description {
  if (_finishing || _finished)
    return;
  _error = [NSError errorWithDomain:@"SecondMacDisplay" code:1
                          userInfo:@{NSLocalizedDescriptionKey:description}];
  _finishing = YES;
  [self stopIfReady];
}
- (void)startWithFilter:(SCContentFilter *)filter
         configuration:(SCStreamConfiguration *)configuration
            completion:(void (^)(CGImageRef, NSError *))completion {
  _completion = [completion copy];
  _stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
  NSError *error = nil;
  if (![_stream addStreamOutput:self type:SCStreamOutputTypeScreen
            sampleHandlerQueue:dispatch_get_main_queue() error:&error]) {
    [self complete:error];
    return;
  }
  _starting = YES;
  [_stream startCaptureWithCompletionHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_starting = NO;
      if (error)
        [self complete:error];
      else if (self->_finishing)
        [self stopIfReady];
    });
  }];
  __weak SMFrameCapture *weak = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{ [weak fail:@"The guest display did not produce a complete frame."]; });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{ [self complete:error]; });
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample
        ofType:(SCStreamOutputType)type {
  if (_finishing || _finished || type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample))
    return;
  NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, NO);
  NSNumber *status = [attachments.firstObject objectForKey:SCStreamFrameInfoStatus];
  if (!status || status.integerValue != SCFrameStatusComplete)
    return;
  CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
  if (!pixels || CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
    [self fail:@"The guest frame could not be read."];
    return;
  }
  size_t width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels);
  size_t stride = CVPixelBufferGetBytesPerRow(pixels);
  CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 0, color,
      kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
  CGColorSpaceRelease(color);
  if (bitmap) {
    uint8_t *destination = CGBitmapContextGetData(bitmap);
    const uint8_t *source = CVPixelBufferGetBaseAddress(pixels);
    for (size_t y = 0; y < height; y++)
      memcpy(destination + y * CGBitmapContextGetBytesPerRow(bitmap), source + y * stride, width * 4);
    _image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
  }
  CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  if (!_image) {
    [self fail:@"The guest frame could not be copied."];
    return;
  }
  _finishing = YES;
  [self stopIfReady];
}
@end

@interface SMWindowDelegate : NSObject <NSWindowDelegate>
- (void)applicationVisibilityChanged:(NSNotification *)notification;
@end
@implementation SMWindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)sender {
  hideDesktop();
  return NO;
}
- (void)applicationVisibilityChanged:(NSNotification *)notification {
  if (displayInUse)
    return;
  if (desktopIsVisible())
    prepareDisplay();
  else
    releaseHiddenDisplay();
}
- (void)windowDidMiniaturize:(NSNotification *)notification {
  [self applicationVisibilityChanged:notification];
}
- (void)windowDidDeminiaturize:(NSNotification *)notification {
  [self applicationVisibilityChanged:notification];
}
@end
static SMWindowDelegate *windowDelegate;

void SMDisplayInitialize(VZVirtualMachine *machine) {
  [NSApplication sharedApplication];
  vm = machine;
  if (!shortcutMonitor)
    shortcutMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp
        handler:^NSEvent *(NSEvent *event) { return forwardGuestShortcut(event); }];
  if (!windowDelegate) {
    windowDelegate = [SMWindowDelegate new];
    for (NSString *name in @[NSApplicationDidHideNotification, NSApplicationDidUnhideNotification])
      [NSNotificationCenter.defaultCenter addObserver:windowDelegate
          selector:@selector(applicationVisibilityChanged:) name:name object:NSApp];
  }
  // The private socket needs no rendering window. Create one only for an
  // explicit viewer, capture, or pointer-coordinate conversion request.
}
static void prepareDisplay(void) {
  if (view.virtualMachine)
    return;
  if (!view)
    view = [[VZVirtualMachineView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768)];
  view.virtualMachine = vm;
  if (!window) {
    window = [[NSWindow alloc] initWithContentRect:view.frame
                                       styleMask:NSWindowStyleMaskBorderless
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    window.releasedWhenClosed = NO;
    window.title = @"Second Mac virtual display";
    window.delegate = windowDelegate;
  }
  window.contentView = view;
  displayReadyAfter = NSProcessInfo.processInfo.systemUptime + 0.2;
}
static void captureScreen(NSDictionary *command) {
  NSInteger windowNumber = window.windowNumber;
  CGRect sourceRect =
      CGRectMake(0, window.frame.size.height - view.bounds.size.height,
                 view.bounds.size.width, view.bounds.size.height);
  [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(
                          SCShareableContent *content, NSError *error) {
    SCWindow *own = nil;
    for (SCWindow *w in content.windows) {
      if (w.windowID == windowNumber) {
        own = w;
        break;
      }
    }
    if (!own) {
      reply(@{
        @"error" : error.localizedDescription ?: @"Own window unavailable"
      });
      return;
    }
    SCContentFilter *filter =
        [[SCContentFilter alloc] initWithDesktopIndependentWindow:own];
    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.width = 1024;
    config.height = 768;
    config.showsCursor = NO;
    config.ignoreShadowsSingleWindow = YES;
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.sourceRect = sourceRect;
    dispatch_async(dispatch_get_main_queue(), ^{
      activeCapture = [SMFrameCapture new];
      [activeCapture
        startWithFilter:filter
                 configuration:config
             completion:^(CGImageRef cg, NSError *error) {
               if (error || !cg) {
                 reply(@{@"error" : error.localizedDescription ?: @"No image"});
                 return;
               }
               NSBitmapImageRep *rep =
                   [[NSBitmapImageRep alloc] initWithCGImage:cg];

               if ([command[@"op"] isEqual:@"screenshot"]) {
                 NSData *png =
                     [rep representationUsingType:NSBitmapImageFileTypePNG
                                       properties:@{}];
                 reply(@{
                   @"png" : [png base64EncodedStringWithOptions:0],
                   @"width" : @1024,
                   @"height" : @768
                 });
                 return;
               }
               VNRecognizeTextRequest *ocr = [VNRecognizeTextRequest new];
               ocr.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
               ocr.recognitionLanguages = @[ @"en-US" ];
               if (![[[VNImageRequestHandler alloc] initWithCGImage:cg
                                                            options:@{}]
                       performRequests:@[ ocr ]
                                 error:&error]) {
                 reply(
                     @{@"error" : error.localizedDescription ?: @"OCR failed"});
                 return;
               }
               NSMutableArray *rows = [NSMutableArray array];
               for (VNRecognizedTextObservation *row in ocr.results) {
                 VNRecognizedText *text = [row topCandidates:1].firstObject;
                 CGRect b = row.boundingBox;
                 [rows addObject:@{
                   @"text" : text.string,
                   @"x" :
                       @((b.origin.x + b.size.width / 2) * CGImageGetWidth(cg)),
                   @"y" : @((1 - b.origin.y - b.size.height / 2) *
                            CGImageGetHeight(cg))
                 }];
               }
               reply(@{
                 @"rows" : rows,
                 @"width" : @(CGImageGetWidth(cg)),
                 @"height" : @(CGImageGetHeight(cg))
               });
             }];
    });
  }];
}
static void screen(NSDictionary *command) {
  displayInUse = YES;
  prepareDisplay();
  // Only our own guest window is ever eligible for capture. A hidden capture
  // briefly attaches its view without activating an app or capturing the host.
  if (!desktopIsVisible()) {
    // A permission watcher must not reopen a desktop the user hid/minimized.
    // Temporarily move its view into a nonactivating capture window. Its real
    // desktop and AppKit Hide/Minimize state remain unchanged throughout.
    if (desktopVisible) {
      captureDesktop = window;
      window = [[NSWindow alloc] initWithContentRect:view.bounds
          styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
      window.releasedWhenClosed = NO;
      window.canHide = NO;
      window.contentView = view;
    }
    window.styleMask = NSWindowStyleMaskBorderless;
    window.ignoresMouseEvents = YES;
    [window setContentSize:NSMakeSize(1024, 768)];
    NSRect screen = NSScreen.mainScreen.frame;
    [window setFrameOrigin:NSMakePoint(NSMaxX(screen) - 1, NSMinY(screen))];
    if (!captureDesktop)
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  }
  if (NSApp.hidden && !captureDesktop)
    [NSApp unhideWithoutActivation];
  if (!window.visible)
    [window orderBack:nil];
  [view displayIfNeeded];
  // Let the newly attached framebuffer reach WindowServer before taking its
  // first frame. Existing visible viewers do not pay this attachment delay.
  NSTimeInterval delay = MAX(0, displayReadyAfter - NSProcessInfo.processInfo.systemUptime);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ captureScreen(command); });
}
static void keyEvent(id keyboard, unsigned short code, NSEventType type) {
  NSEvent *event =
      [NSEvent keyEventWithType:type
                             location:NSZeroPoint
                        modifierFlags:0
                            timestamp:NSProcessInfo.processInfo.systemUptime
                         windowNumber:window.windowNumber
                              context:nil
                           characters:@""
          charactersIgnoringModifiers:@""
                            isARepeat:NO
                              keyCode:code];
  [keyboard sendKeyEvents:@[ [[NSClassFromString(@"_VZKeyEvent") alloc]
                              initWithEvent:event] ]];
}
static void pointerEvent(NSDictionary *step, NSInteger buttons) {
  NSPoint p = NSMakePoint([step[@"x"] doubleValue] * view.bounds.size.width / 1024,
      (768 - [step[@"y"] doubleValue]) * view.bounds.size.height / 768);
  NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:p
      modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
      windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
  Class cls = NSClassFromString(@"_VZScreenCoordinatePointerEvent");
  CGPoint location = [(NSObject *)[[cls alloc] initWithEvent:event view:view] location];
  // The adapter reads host physical buttons; replace them with explicit guest bits.
  [[vm _pointingDevices].firstObject sendPointerEvents:@[
      [[cls alloc] initWithLocation:location pressedButtons:buttons]]];
}
static void pointerSteps(NSArray *steps, NSUInteger index, NSTimeInterval start) {
  NSDictionary *step = steps[index];
  NSTimeInterval delay = MAX(0, start + [step[@"at"] doubleValue] - NSProcessInfo.processInfo.systemUptime);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    @try {
      if (step[@"dx"]) {
        double dx = [step[@"dx"] doubleValue], dy = [step[@"dy"] doubleValue];
        id event = [[NSClassFromString(@"_VZScrollWheelEvent") alloc]
            initWithScrollingDeltaX:dx scrollingDeltaY:dy
            acceleratedScrollingDeltaX:dx acceleratedScrollingDeltaY:dy scrollPhase:0 momentumPhase:0];
        [[vm _pointingDevices].firstObject sendScrollWheelEvents:@[event]];
      } else {
        pointerEvent(step, [step[@"buttons"] integerValue]);
      }
      if (index + 1 < steps.count) pointerSteps(steps, index + 1, start);
      else reply(@{@"ok":@YES});
    } @catch (NSException *exception) {
      // Do not leave a guest mouse button held after a failed gesture.
      @try { pointerEvent(step, 0); } @catch (NSException *ignored) {}
      reply(@{@"error":@"Guest pointer operation failed; inspect the screen before retrying"});
    }
  });
}
static void handle(NSDictionary *c) {
  NSString *op = c[@"op"];
  if ([op isEqual:@"screen"] || [op isEqual:@"screenshot"]) {
    screen(c);
    return;
  }
  if ([op isEqual:@"status"]) {
    reply(@{
      @"version" : @3,
      @"features" : @[ @"pointer-v2", @"key-hold-v1" ],
      @"key_hold_ms" : @(SMKeyDefaultHoldMS),
      @"key_hold_range_ms" : @[ @(SMKeyMinHoldMS), @(SMKeyMaxHoldMS) ],
      @"pid" : @(getpid()),
      @"width" : @1024,
      @"height" : @768,
      @"backend" : @"virtual-devices",
      @"gui_visible" : @(desktopIsVisible()),
      @"rendering" : @((BOOL)(view.virtualMachine != nil))
    });
    return;
  }
  if ([op isEqual:@"show"]) {
    prepareDisplay();
    desktopVisible = YES;
    window.ignoresMouseEvents = NO;
    window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskMiniaturizable |
                       NSWindowStyleMaskResizable;
    [window setContentSize:NSMakeSize(1024, 768)];
    [window center];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp unhideWithoutActivation];
    if (window.miniaturized)
      [window deminiaturize:nil];
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
    displayReadyAfter = NSProcessInfo.processInfo.systemUptime + 0.2;
    reply(@{@"ok" : @YES});
    return;
  }
  if ([op isEqual:@"hide"]) {
    hideDesktop();
    reply(@{@"ok" : @YES});
    return;
  }
  if ([op isEqual:@"key"]) {
    id hold = c[@"hold_ms"] ?: @(SMKeyDefaultHoldMS);
    id flags = c[@"flags"] ?: @0;
    NSUInteger allowed = NSEventModifierFlagShift | NSEventModifierFlagControl |
        NSEventModifierFlagOption | NSEventModifierFlagCommand;
    if (![c[@"code"] isKindOfClass:NSNumber.class] ||
        [c[@"code"] doubleValue] != [c[@"code"] unsignedIntegerValue] ||
        [c[@"code"] unsignedIntegerValue] > 127 || !SMKeyHoldValid(hold) ||
        ![flags isKindOfClass:NSNumber.class] || [flags doubleValue] != [flags unsignedIntegerValue] ||
        ([flags unsignedIntegerValue] & ~allowed)) {
      reply(@{@"error" : @"Invalid guest key code, modifiers or hold duration (10–5000 ms)"});
      return;
    }
    id keyboard = [vm _keyboards].firstObject;
    if (vm.state != VZVirtualMachineStateRunning || ![keyboard respondsToSelector:@selector(sendKeyEvents:)]) {
      reply(@{@"error":@"Guest virtual keyboard is unavailable or the VM is not running"});
      return;
    }
    SMPressKey([c[@"code"] unsignedShortValue], [flags unsignedIntegerValue], [hold integerValue],
        ^(unsigned short code, BOOL down) { keyEvent(keyboard, code, down ? NSEventTypeKeyDown : NSEventTypeKeyUp); },
        ^(BOOL success) { reply(success ? @{@"ok":@YES} :
            @{@"error":@"Guest key operation failed; releases were attempted. Inspect the guest before retrying"}); });
    return;
  }
  if ([@[@"click", @"move", @"drag", @"scroll"] containsObject:op]) {
    NSArray *steps = SMPointerPlan(c);
    if (!steps) { reply(@{@"error":@"Invalid guest pointer arguments"}); return; }
    id pointer = [vm _pointingDevices].firstObject;
    if (!pointer || ![pointer respondsToSelector:@selector(sendPointerEvents:)] ||
        ([op isEqual:@"scroll"] && (![pointer respondsToSelector:@selector(sendScrollWheelEvents:)] ||
        ![NSClassFromString(@"_VZScrollWheelEvent") instancesRespondToSelector:
          @selector(initWithScrollingDeltaX:scrollingDeltaY:acceleratedScrollingDeltaX:acceleratedScrollingDeltaY:scrollPhase:momentumPhase:)]))) {
      reply(@{@"error":@"Guest virtual pointer API is unavailable on this host build"});
      return;
    }
    displayInUse = YES;
    prepareDisplay();
    pointerSteps(steps, 0, NSProcessInfo.processInfo.systemUptime);
    return;
  }
  reply(@{@"error" : @"Unknown operation"});
}
void SMDisplayCommand(NSDictionary *command,
                      void (^completion)(NSDictionary *)) {
  if (SMKeyboardBusy()) {
    completion(@{@"error":@"A guest key operation is still in progress"});
    return;
  }
  BOOL keyRequest = [command[@"op"] isEqual:@"key"];
  BOOL pointerRequest = [@[@"click", @"move", @"drag", @"scroll"] containsObject:command[@"op"]];
  if (!vm || (keyRequest && ![vm respondsToSelector:@selector(_keyboards)]) ||
      (pointerRequest && ![vm respondsToSelector:@selector(_pointingDevices)])) {
    completion(@{
      @"error" : @"Guest virtual input API is unavailable on this host build"
    });
    return;
  }
  response = [completion copy];
  @try {
    handle(command);
  } @catch (NSException *exception) {
    reply(@{@"error" : @"Virtual display operation failed"});
  }
}
