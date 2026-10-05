#import "SecondMacDisplay.h"
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

// Private host Unix socket; never bridged to a guest, TCP, or the host desktop.
// Serialize requests because the display and input devices share one VM queue.
int SMStartHostSocket(NSString *directory, const char *path,
                     void (^handler)(NSDictionary *, void (^)(NSDictionary *))) {
  // Framework IPC and disconnected clients must report EPIPE instead of
  // terminating the entire VM. SO_NOSIGPIPE below also protects our own socket.
  struct sigaction brokenPipe = {.sa_handler = SIG_IGN};
  sigemptyset(&brokenPipe.sa_mask);
  if (sigaction(SIGPIPE, &brokenPipe, NULL) != 0)
    return -1;
  if (chdir(directory.fileSystemRepresentation) != 0)
    return -1;
  struct stat st;
  if (lstat(path, &st) == 0) {
    if (!S_ISSOCK(st.st_mode) || st.st_uid != geteuid())
      return -1;
    if (unlink(path) != 0)
      return -1;
  } else if (errno != ENOENT)
    return -1;
  int server = socket(AF_UNIX, SOCK_STREAM, 0);
  if (server < 0)
    return -1;
  fcntl(server, F_SETFD, FD_CLOEXEC);
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  strlcpy(address.sun_path, path, sizeof(address.sun_path));
  mode_t old = umask(0077);
  int result = bind(server, (struct sockaddr *)&address, sizeof(address));
  umask(old);
  if (result != 0 || chmod(path, 0600) != 0 || listen(server, 8) != 0) {
    close(server);
    return -1;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    while (YES) {
      @autoreleasepool {
        int client = accept(server, NULL, NULL);
        if (client < 0) {
          if (errno == EINTR)
            continue;
          break;
        }
        fcntl(client, F_SETFD, FD_CLOEXEC);
        uid_t user;
        gid_t group;
        if (getpeereid(client, &user, &group) != 0 || user != geteuid()) {
          close(client);
          continue;
        }
        int yes = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        struct timeval timeout = {.tv_sec = 10};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        NSMutableData *input = [NSMutableData data];
        BOOL complete = NO;
        while (input.length < 262144) {
          char byte;
          ssize_t n = read(client, &byte, 1);
          if (n != 1)
            break;
          if (byte == '\n') {
            complete = YES;
            break;
          }
          [input appendBytes:&byte length:1];
        }
        id value = complete ? [NSJSONSerialization JSONObjectWithData:input
                                                              options:0
                                                                error:NULL]
                            : nil;
        if (![value isKindOfClass:NSDictionary.class]) {
          close(client);
          continue;
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSData *output = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
          handler(value, ^(NSDictionary *reply) {
            output = [NSJSONSerialization dataWithJSONObject:reply
                                                     options:0
                                                       error:NULL];
            dispatch_semaphore_signal(done);
          });
        });
        if (dispatch_semaphore_wait(
                done, dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC)) !=
            0) {
          close(client);
          // Never mix a late OCR response with a subsequent client's command.
          dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
          continue;
        }
        const char *bytes = output.bytes;
        NSUInteger left = output.length;
        while (left > 0) {
          ssize_t n = write(client, bytes, left);
          if (n <= 0)
            break;
          bytes += n;
          left -= n;
        }
        if (left == 0)
          write(client, "\n", 1);
        close(client);
      }
    }
    close(server);
  });
  return 0;
}

static BOOL controlStarted = NO;
static BOOL controlEnabled = NO;
BOOL SMControlEnabled(void) { return controlEnabled; }

int SMStartControl(VZVirtualMachine *machine, NSString *directory) {
  if (controlStarted) { controlEnabled = YES; return 0; }
  SMDisplayInitialize(machine);
  int result = SMStartHostSocket(directory, "ui.sock", ^(NSDictionary *command, void (^reply)(NSDictionary *)) {
    // Viewing our own VM remains available when scripted input/capture is off.
    if (!controlEnabled && ![@[@"status", @"show", @"hide"] containsObject:command[@"op"]]) {
      reply(@{@"error": @"Guest UI automation is disabled."}); return;
    }
    SMDisplayCommand(command, reply);
  });
  if (result == 0) controlStarted = controlEnabled = YES;
  return result;
}

int SMSetControlEnabled(VZVirtualMachine *machine, NSString *directory, BOOL enabled) {
  int result = SMStartControl(machine, directory);
  if (result == 0) controlEnabled = enabled;
  return result;
}
