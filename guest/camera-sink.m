// Feed decoded video to OBS's signed virtual camera using public CoreMediaIO.
// No screen, physical camera, microphone, Accessibility or network access.
#import <Foundation/Foundation.h>
#import <CoreMediaIO/CoreMediaIO.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <signal.h>
#import <unistd.h>

static const size_t width = 1280, height = 720;
static volatile sig_atomic_t stopped = 0;
static void stop(int sig) { stopped = 1; }
static void fail(NSString *message) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
static NSData *property(CMIOObjectID object, CMIOObjectPropertySelector selector) {
  CMIOObjectPropertyAddress address = {selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
  UInt32 length = 0;
  if (CMIOObjectGetPropertyDataSize(object, &address, 0, NULL, &length) != noErr || length > 1024*1024) return nil;
  NSMutableData *data = [NSMutableData dataWithLength:length];
  if (CMIOObjectGetPropertyData(object, &address, 0, NULL, length, &length, data.mutableBytes) != noErr) return nil;
  return data;
}
static NSString *deviceUID(CMIODeviceID device) {
  CMIOObjectPropertyAddress address = {kCMIODevicePropertyDeviceUID, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
  CFStringRef uid = NULL; UInt32 used = 0;
  if (CMIOObjectGetPropertyData(device, &address, 0, NULL, sizeof(uid), &used, &uid) != noErr || !uid) return nil;
  return CFBridgingRelease(uid);
}
static void queueChanged(CMIOStreamID stream, void *token, void *refcon) {}

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSString *info = @"/Applications/OBS.app/Contents/PlugIns/mac-virtualcam.plugin/Contents/Info.plist";
    NSString *wanted = [NSDictionary dictionaryWithContentsOfFile:info][@"OBSCameraDeviceUUID"];
    if (!wanted.length) fail(@"OBS camera identity is unavailable; run vm camera setup on the host.");
    NSData *devices = property(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices);
    CMIODeviceID device = 0; CMIOStreamID sink = 0;
    const CMIODeviceID *ids = devices.bytes;
    for (NSUInteger i = 0; i < devices.length / sizeof(*ids); i++) {
      if ([[deviceUID(ids[i]) uppercaseString] isEqual:wanted.uppercaseString]) { device = ids[i]; break; }
    }
    if (!device) fail(@"OBS Virtual Camera is unavailable. Enable its guest Camera Extension with vm camera setup.");
    NSData *streams = property(device, kCMIODevicePropertyStreams);
    const CMIOStreamID *streamIDs = streams.bytes;
    for (NSUInteger i = 0; i < streams.length / sizeof(*streamIDs); i++) {
      NSData *direction = property(streamIDs[i], kCMIOStreamPropertyDirection);
      if (direction.length == sizeof(UInt32) && *(const UInt32 *)direction.bytes == 0) { sink = streamIDs[i]; break; }
    }
    if (!sink) fail(@"OBS has no writable camera stream. Update OBS and rerun vm camera setup.");
    if (argc == 2 && strcmp(argv[1], "--check") == 0) { puts("OBS Virtual Camera ready"); return 0; }
    if (argc != 1) fail(@"Usage: camera-sink [--check]; input is 1280x720 BGRA video at 30 fps.");
    CMSimpleQueueRef queue = NULL;
    if (CMIOStreamCopyBufferQueue(sink, queueChanged, NULL, &queue) != noErr || !queue) fail(@"Cannot open OBS camera queue.");
    if (CMIODeviceStartStream(device, sink) != noErr) fail(@"Cannot start OBS camera output; stop any other guest OBS virtual-camera producer.");
    signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGPIPE, SIG_IGN);
    NSMutableData *frame = [NSMutableData dataWithLength:width*height*4];
    size_t used = 0; unsigned long count = 0;
    while (!stopped) {
      ssize_t n = read(STDIN_FILENO, (char *)frame.mutableBytes + used, frame.length - used);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) break;
      used += n;
      if (used != frame.length) continue;
      used = 0;
      // Never retain a backlog: consumers see the newest complete frame.
      if (CMSimpleQueueGetFullness(queue) >= 1.0) continue;
      @autoreleasepool {
        CVPixelBufferRef pixels = NULL;
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixels) != kCVReturnSuccess) break;
        CVPixelBufferLockBaseAddress(pixels, 0);
        for (size_t y = 0; y < height; y++) memcpy((char *)CVPixelBufferGetBaseAddress(pixels) + y*CVPixelBufferGetBytesPerRow(pixels), (char *)frame.bytes + y*width*4, width*4);
        CVPixelBufferUnlockBaseAddress(pixels, 0);
        CMVideoFormatDescriptionRef format = NULL;
        CMSampleBufferRef sample = NULL;
        CMSampleTimingInfo time = {CMTimeMake(1, 30), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
        OSStatus result = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixels, &format);
        if (result == noErr) result = CMSampleBufferCreateReadyWithImageBuffer(NULL, pixels, format, &time, &sample);
        if (format) CFRelease(format);
        CVPixelBufferRelease(pixels);
        if (result != noErr) break;
        // The CMIO sink consumes/releases enqueued sample buffers.
        if (CMSimpleQueueEnqueue(queue, sample) != noErr) CFRelease(sample);
        else count++;
      }
    }
    CMIODeviceStopStream(device, sink);
    CFRelease(queue);
    fprintf(stderr, "Camera receiver stopped (%lu frames).\n", count);
    return used ? 1 : 0;
  }
}
