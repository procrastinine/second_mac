#import "../lib/display/Display.m"
#import <sys/socket.h>
#import <sys/un.h>

// Receive real _VZKeyEvent objects without posting to any actual VM or host.
@interface KeyReceiver : NSObject
@property NSMutableArray<NSNumber *> *times;
@end
@implementation KeyReceiver
- (void)sendKeyEvents:(NSArray *)events {
  for (id event in events) {
    NSCAssert([event isKindOfClass:NSClassFromString(@"_VZKeyEvent")], @"Expected native virtual keyboard event");
    [self.times addObject:@(NSProcessInfo.processInfo.systemUptime)];
  }
}
@end
@interface KeyMachine : NSObject
@property KeyReceiver *receiver;
@property VZVirtualMachineState state;
@end
@implementation KeyMachine
- (NSArray *)_keyboards { return @[self.receiver]; }
@end
static void check(BOOL value, NSString *name) {
  if (!value) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); exit(1); }
}
static void pump(double seconds) {
  double end = NSProcessInfo.processInfo.systemUptime + seconds;
  do { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false); } while (NSProcessInfo.processInfo.systemUptime < end);
}
static NSDictionary *command(NSDictionary *input) {
  __block NSDictionary *result = nil;
  SMDisplayCommand(input, ^(NSDictionary *value) { result = value; });
  double end = NSProcessInfo.processInfo.systemUptime + 2;
  while (!result && NSProcessInfo.processInfo.systemUptime < end) pump(0.002);
  check(result != nil, @"command completes");
  return result;
}
int main(void) {
  @autoreleasepool {
    (void)[VZVirtualMachine class];
    KeyReceiver *receiver = [KeyReceiver new]; receiver.times = [NSMutableArray array];
    KeyMachine *machine = [KeyMachine new]; machine.receiver = receiver; machine.state = VZVirtualMachineStateRunning;
    vm = (VZVirtualMachine *)(id)machine;
    NSDictionary *status = command(@{@"op":@"status"});
    check([status[@"features"] containsObject:@"key-hold-v1"] && [status[@"key_hold_ms"] integerValue] == 80,
        @"running controller advertises timing contract");
    for (NSNumber *ms in @[@80,@250]) {
      [receiver.times removeAllObjects];
      NSMutableDictionary *input = [@{@"op":@"key",@"code":@0} mutableCopy];
      if (ms.integerValue != 80) input[@"hold_ms"] = ms;
      __block NSDictionary *result = nil;
      SMDisplayCommand(input, ^(NSDictionary *value) { result = value; });
      check(result == nil && receiver.times.count == 1, @"reply waits for release");
      __block NSDictionary *busy = nil;
      SMDisplayCommand(@{@"op":@"status"}, ^(NSDictionary *value) { busy = value; });
      check(busy[@"error"] != nil, @"overlapping command cannot replace active completion");
      double end = NSProcessInfo.processInfo.systemUptime + 2;
      while (!result && NSProcessInfo.processInfo.systemUptime < end) pump(0.002);
      check([result[@"ok"] boolValue] && receiver.times.count == 2, @"native command emits one down/up pair");
      double elapsed = receiver.times[1].doubleValue - receiver.times[0].doubleValue;
      check(elapsed * 1000 >= ms.doubleValue - 1, @"native events preserve default/explicit duration");
    }
    [receiver.times removeAllObjects];
    for (id bad in @[@0,@5001,@YES,@10.5,@"80"]) {
      check(command(@{@"op":@"key",@"code":@0,@"hold_ms":bad})[@"error"] != nil, @"invalid duration rejected by native boundary");
    }
    machine.state = VZVirtualMachineStatePaused;
    check(command(@{@"op":@"key",@"code":@0})[@"error"] != nil && receiver.times.count == 0, @"paused VM receives no key-down");
    machine.state = VZVirtualMachineStateRunning;
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    check(SMStartHostSocket(directory, "test.sock", ^(NSDictionary *c, void (^reply)(NSDictionary *)) { SMDisplayCommand(c, reply); }) == 0,
        @"private controller socket starts");
    int client = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {.sun_family=AF_UNIX};
    strlcpy(address.sun_path, "test.sock", sizeof(address.sun_path));
    check(connect(client, (struct sockaddr *)&address, sizeof(address)) == 0, @"test client connects");
    const char *request = "{\"op\":\"key\",\"code\":0,\"hold_ms\":150}\n";
    check(write(client, request, strlen(request)) == strlen(request), @"bounded hold request written");
    close(client);
    pump(0.4);
    check(receiver.times.count == 2 && !SMKeyboardBusy(), @"socket disconnect still releases the virtual key");
    check((receiver.times[1].doubleValue - receiver.times[0].doubleValue) * 1000 >= 149, @"disconnect does not shorten requested hold");
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    puts("Native key command, real VZ event timing, input validation and disconnected-socket checks passed.");
  }
}
