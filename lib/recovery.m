// Temporary offline paired-Recovery runner. Normal operation remains in Tart.
// Display and input are shared with the same host-only controller used by Tart.
#import "display/include/SecondMacDisplay.h"
#import <AppKit/AppKit.h>
#import <Virtualization/Virtualization.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
@interface RecoveryDelegate : NSObject <VZVirtualMachineDelegate>
@end
@implementation RecoveryDelegate
- (void)virtualMachine:(VZVirtualMachine *)machine
      didStopWithError:(NSError *)error {
  fprintf(stderr, "Guest error: %s\n", error.description.UTF8String);
  exit(5);
}
- (void)guestDidStopVirtualMachine:(VZVirtualMachine *)machine {
  exit(0);
}
@end
static RecoveryDelegate *delegate;
static VZVirtualMachine *vm;
static int lockFD;
static void reply(NSDictionary *value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                 options:0
                                                   error:NULL];
  fwrite(data.bytes, 1, data.length, stdout);
  puts("");
  fflush(stdout);
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 2) {
      fputs("Expected a stopped managed VM directory.\n", stderr);
      return 2;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSString *dir = @(argv[1]);
    NSString *path = [dir stringByAppendingPathComponent:@"config.json"];
    lockFD = open(path.fileSystemRepresentation, O_RDWR | O_NOFOLLOW);
    struct flock lk = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
    if (lockFD < 0 || fcntl(lockFD, F_SETLK, &lk) < 0)
      return 3;
    struct stat st;
    if (fstat(lockFD, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 2 ||
        st.st_size > 1048576)
      return 3;
    NSMutableData *data = [NSMutableData dataWithLength:st.st_size];
    pread(lockFD, data.mutableBytes, data.length, 0);
    NSDictionary *c = [NSJSONSerialization JSONObjectWithData:data
                                                      options:0
                                                        error:NULL];
    NSError *error = nil;
    if (![c[@"os"] isEqual:@"darwin"] ||
        [[NSFileManager defaultManager]
            fileExistsAtPath:[dir stringByAppendingPathComponent:@"state.vzvmsave"]])
      return 3;
    for (NSString *name in @[ @"disk.img", @"nvram.bin" ]) {
      struct stat file;
      if (lstat([[dir stringByAppendingPathComponent:name]
                    fileSystemRepresentation],
                &file) != 0 ||
          !S_ISREG(file.st_mode))
        return 3;
    }
    VZMacPlatformConfiguration *platform =
        [[VZMacPlatformConfiguration alloc] init];
    platform.hardwareModel = [[VZMacHardwareModel alloc]
        initWithDataRepresentation:
            [[NSData alloc] initWithBase64EncodedString:c[@"hardwareModel"]
                                                options:0]];
    platform.machineIdentifier = [[VZMacMachineIdentifier alloc]
        initWithDataRepresentation:[[NSData alloc]
                                       initWithBase64EncodedString:c[@"ecid"]
                                                           options:0]];
    platform.auxiliaryStorage = [[VZMacAuxiliaryStorage alloc]
        initWithURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:
                                                    @"nvram.bin"]]];
    VZVirtualMachineConfiguration *cfg =
        [[VZVirtualMachineConfiguration alloc] init];
    cfg.platform = platform;
    cfg.bootLoader = [[VZMacOSBootLoader alloc] init];
    cfg.CPUCount = MAX(2, [c[@"cpuCountMin"] unsignedIntegerValue]);
    cfg.memorySize = MAX(8ull * 1024 * 1024 * 1024,
                         [c[@"memorySizeMin"] unsignedLongLongValue]);
    VZMacGraphicsDeviceConfiguration *graphics =
        [[VZMacGraphicsDeviceConfiguration alloc] init];
    graphics.displays = @[ [[VZMacGraphicsDisplayConfiguration alloc]
        initWithWidthInPixels:1024
               heightInPixels:768
                pixelsPerInch:80] ];
    cfg.graphicsDevices = @[ graphics ];
    cfg.keyboards = @[ [[VZUSBKeyboardConfiguration alloc] init] ];
    cfg.pointingDevices =
        @[ [[VZUSBScreenCoordinatePointingDeviceConfiguration alloc] init] ];
    cfg.entropyDevices = @[ [[VZVirtioEntropyDeviceConfiguration alloc] init] ];
    VZDiskImageStorageDeviceAttachment *disk =
        [[VZDiskImageStorageDeviceAttachment alloc]
                    initWithURL:[NSURL fileURLWithPath:
                                           [dir stringByAppendingPathComponent:
                                                    @"disk.img"]]
                       readOnly:NO
                    cachingMode:VZDiskImageCachingModeAutomatic
            synchronizationMode:VZDiskImageSynchronizationModeFull
                          error:&error];
    if (!disk) {
      fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
      return 4;
    }
    cfg.storageDevices =
        @[ [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:disk] ];
    if (![cfg validateWithError:&error]) {
      fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
      return 4;
    }
    vm = [[VZVirtualMachine alloc] initWithConfiguration:cfg];
    delegate = [RecoveryDelegate new];
    vm.delegate = delegate;
    SMDisplayInitialize(vm);
    if (![vm respondsToSelector:@selector(_keyboards)] ||
        !NSClassFromString(@"_VZKeyEvent")) {
      fputs("This macOS build lacks the guest keyboard interface.\n", stderr);
      return 4;
    }
    VZMacOSVirtualMachineStartOptions *opts =
        [[VZMacOSVirtualMachineStartOptions alloc] init];
    opts.startUpFromMacOSRecovery = YES;
    [vm startWithOptions:opts
        completionHandler:^(NSError *error) {
          if (error) {
            reply(@{@"error" : error.localizedDescription});
            exit(1);
          }
          reply(@{@"ready" : @YES});
          dispatch_async(dispatch_get_global_queue(0, 0), ^{
            char *line = NULL;
            size_t n = 0;
            while (getline(&line, &n, stdin) > 0) {
              @autoreleasepool {
                NSData *data = [[@(line)
                    stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet]
                    dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *c = [NSJSONSerialization JSONObjectWithData:data
                                                                  options:0
                                                                    error:NULL];
                dispatch_async(dispatch_get_main_queue(), ^{
                  if ([c[@"op"] isEqual:@"stop"]) {
                    [vm stopWithCompletionHandler:^(NSError *e) {
                      reply(e ? @{@"error" : e.localizedDescription}
                              : @{@"ok" : @YES});
                      exit(e ? 1 : 0);
                    }];
                  } else {
                    SMDisplayCommand(c, ^(NSDictionary *value) {
                      reply(value);
                    });
                  }
                });
              }
            }
            free(line);
            dispatch_async(dispatch_get_main_queue(), ^{
              if (vm.state == VZVirtualMachineStateRunning) {
                [vm stopWithCompletionHandler:^(NSError *error) {
                  exit(error ? 1 : 0);
                }];
              } else {
                exit(0);
              }
            });
          });
        }];
    [NSApp run];
  }
}
