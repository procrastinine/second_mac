// Capture exactly OBS's virtual video device. Never select a default device,
// physical camera, display or audio input. Permission belongs to this app.
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <signal.h>
#import <unistd.h>
#import <sys/file.h>
#import <fcntl.h>

static const size_t width = 1280, height = 720;
static AVCaptureSession *session;
static long limit = 0;
static dispatch_source_t lifetime;
static void fail(NSString *message) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
@interface Video : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property CIContext *context;
@property double previous;
@property long count;
@end
@implementation Video
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
  double now = NSProcessInfo.processInfo.systemUptime;
  if (now - self.previous < 1.0/31.0) return;
  self.previous = now;
  CVPixelBufferRef input = CMSampleBufferGetImageBuffer(sample), pixels = NULL;
  if (!input) return;
  NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
  if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixels) != kCVReturnSuccess) return;
  CIImage *image = [CIImage imageWithCVPixelBuffer:input];
  CGFloat scale = MIN(width/image.extent.size.width, height/image.extent.size.height);
  image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
  image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation((width-image.extent.size.width)/2, (height-image.extent.size.height)/2)];
  image = [image imageByCompositingOverImage:[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]];
  [self.context render:image toCVPixelBuffer:pixels];
  CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  BOOL success = YES;
  for (size_t y = 0; y < height && success; y++) {
    const char *p = (char *)CVPixelBufferGetBaseAddress(pixels) + y*CVPixelBufferGetBytesPerRow(pixels);
    size_t left = width*4;
    while (left) {
      ssize_t n = write(STDOUT_FILENO, p, left);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { success = NO; break; }
      p += n; left -= n;
    }
  }
  CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(pixels);
  if (!success) exit(0);
  if (limit && ++self.count >= limit) exit(0);
}
@end
static Video *video;
static void start(AVCaptureDevice *device) {
  NSError *error = nil;
  AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  if (!input) fail(@"Cannot open OBS Virtual Camera. Start Virtual Camera in host OBS first.");
  session = [AVCaptureSession new];
  if (![session canAddInput:input]) fail(@"OBS video input is unavailable.");
  [session addInput:input];
  AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
  output.alwaysDiscardsLateVideoFrames = YES;
  output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
  video = [Video new]; video.context = [CIContext contextWithOptions:nil];
  [output setSampleBufferDelegate:video queue:dispatch_queue_create("local.second-mac.obs-video", DISPATCH_QUEUE_SERIAL)];
  if (![session canAddOutput:output]) fail(@"OBS video output is unavailable.");
  [session addOutput:output];
  [session startRunning];
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    signal(SIGPIPE, SIG_IGN);
    if (argc == 3 && strcmp(argv[1], "--frames") == 0) limit = MAX(1, atol(argv[2]));
    else if (argc == 4 && strcmp(argv[1], "--lifetime") == 0) {
      NSString *path = @(argv[2]), *generation = @(argv[3]);
      lifetime = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
      dispatch_source_set_timer(lifetime, DISPATCH_TIME_NOW, NSEC_PER_SEC/2, NSEC_PER_SEC/20);
      dispatch_source_set_event_handler(lifetime, ^{
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![state isKindOfClass:NSDictionary.class] || ![state[@"generation"] isEqual:generation]) exit(0);
        NSString *lockPath = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"camera-owner.lock"];
        int fd = open(lockPath.fileSystemRepresentation, O_RDONLY|O_NOFOLLOW);
        if (fd < 0) exit(0);
        int result = flock(fd, LOCK_SH|LOCK_NB), saved = errno;
        close(fd);
        if (result == 0 || saved != EWOULDBLOCK) exit(0);
      });
      dispatch_resume(lifetime);
    }
    else if (argc != 1 && !(argc == 2 && strcmp(argv[1], "--check") == 0)) fail(@"Invalid camera-source arguments.");
    NSString *path = @"/Applications/OBS.app/Contents/PlugIns/mac-virtualcam.plugin/Contents/Info.plist";
    NSString *wanted = [NSDictionary dictionaryWithContentsOfFile:path][@"OBSCameraDeviceUUID"];
    if (!wanted.length) fail(@"Install host OBS and enable its Virtual Camera extension first.");
    AVCaptureDevice *selected = nil;
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
    for (AVCaptureDevice *device in discovery.devices) {
      if ([device.uniqueID.uppercaseString isEqual:wanted.uppercaseString]) { selected = device; break; }
    }
    if (!selected) fail(@"OBS Virtual Camera is unavailable. No other camera was opened.");
    if (argc == 2) { puts("OBS Virtual Camera found by device identity"); return 0; }
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusNotDetermined) {
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL allowed) {
        if (!allowed) fail(@"Camera permission denied. Allow Second Mac OBS Bridge in host Privacy & Security > Camera.");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ start(selected); });
      }];
    } else if (status == AVAuthorizationStatusAuthorized) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ start(selected); });
    else fail(@"Camera permission denied. Allow Second Mac OBS Bridge in host Privacy & Security > Camera.");
    dispatch_main();
  }
}
