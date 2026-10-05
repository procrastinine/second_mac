#import "SecondMacDisplay.h"
#import <unistd.h>
#import <sys/stat.h>

// Host-only management endpoint. It is deliberately separate from the UI
// endpoint delegated to guests and is never forwarded into the guest.
int SMStartRuntimeControl(VZVirtualMachine *machine, VZVirtualMachineConfiguration *configuration, NSString *directory) {
  __block BOOL saving = NO;
  return SMStartHostSocket(directory, "runtime.sock", ^(NSDictionary *command, void (^reply)(NSDictionary *)) {
    NSMutableDictionary<NSString *, VZVirtioFileSystemDevice *> *devices = [NSMutableDictionary dictionary];
    NSSet *tags = [NSSet setWithArray:@[@"agent-files", @"agent-readonly", @"agent-linked"]];
    for (VZDirectorySharingDevice *device in machine.directorySharingDevices) {
      if ([device isKindOfClass:VZVirtioFileSystemDevice.class]) {
        VZVirtioFileSystemDevice *fs = (VZVirtioFileSystemDevice *)device;
        if ([tags containsObject:fs.tag]) devices[fs.tag] = fs;
      }
    }
    NSString *op = command[@"op"];
    if (saving && ![op isEqual:@"status"]) {
      reply(@{@"error": @"Memory saving is still in progress; inspect status before retrying."}); return;
    }
    if ([op isEqual:@"ui-set"]) {
      NSNumber *enabled = command[@"enabled"];
      if (![enabled isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)enabled) != CFBooleanGetTypeID() ||
          SMSetControlEnabled(machine, directory, enabled.boolValue) != 0) {
        reply(@{@"error": @"Cannot change the private UI controller."}); return;
      }
    } else if ([op isEqual:@"save-check"] || [op isEqual:@"save-state"]) {
      NSError *error = nil;
      if (![configuration validateSaveRestoreSupportWithError:&error]) {
        reply(@{@"error": error.localizedDescription ?: @"This configuration cannot be saved."}); return;
      }
      if ([op isEqual:@"save-check"]) { reply(@{@"pid": @(getpid()), @"supported": @YES}); return; }
      NSURL *state = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"state.vzvmsave"]];
      NSURL *temporary = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"state.vzvmsave.saving"]];
      if ([[NSFileManager defaultManager] fileExistsAtPath:state.path] ||
          [[NSFileManager defaultManager] fileExistsAtPath:temporary.path]) {
        reply(@{@"error": @"A saved state already exists; resume it before saving again."}); return;
      }
      saving = YES;
      [machine pauseWithCompletionHandler:^(NSError *pauseError) {
        if (pauseError) { saving = NO; reply(@{@"error": pauseError.localizedDescription}); return; }
        [machine saveMachineStateToURL:temporary completionHandler:^(NSError *saveError) {
          NSError *failure = saveError;
          if (!failure) {
            chmod(temporary.fileSystemRepresentation, 0600);
            [[NSFileManager defaultManager] moveItemAtURL:temporary toURL:state error:&failure];
          }
          if (!failure) { saving = NO; reply(@{@"pid": @(getpid()), @"saved": @YES}); return; }
          [[NSFileManager defaultManager] removeItemAtURL:temporary error:nil];
          // A full disk or unsupported device must not kill the running guest.
          [machine resumeWithCompletionHandler:^(NSError *resumeError) {
            saving = NO;
            reply(@{@"error": [NSString stringWithFormat:@"Save failed: %@%@", failure.localizedDescription,
              resumeError ? [@"; resume failed: " stringByAppendingString:resumeError.localizedDescription] : @""]});
          }];
        }];
      }];
      return;
    } else if ([op isEqual:@"shares-set"]) {
      NSArray *rows = command[@"shares"];
      if (![rows isKindOfClass:NSArray.class] || rows.count > 3) {
        reply(@{@"error": @"Expected up to three managed shares."}); return;
      }
      NSMutableDictionary *shares = [NSMutableDictionary dictionary];
      for (id value in rows) {
        if (![value isKindOfClass:NSDictionary.class]) {
          reply(@{@"error": @"Invalid share entry."}); return;
        }
        NSString *tag = value[@"tag"], *path = value[@"path"];
        NSNumber *readOnly = value[@"read_only"];
        if (![tag isKindOfClass:NSString.class] || !devices[tag] || shares[tag] ||
            ![path isKindOfClass:NSString.class] || !path.isAbsolutePath ||
            ![readOnly isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)readOnly) != CFBooleanGetTypeID()) {
          reply(@{@"error": @"Invalid or unavailable managed share."}); return;
        }
        BOOL isDirectory = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
          reply(@{@"error": @"A shared directory is unavailable."}); return;
        }
        VZSharedDirectory *source = [[VZSharedDirectory alloc] initWithURL:[NSURL fileURLWithPath:path] readOnly:readOnly.boolValue];
        shares[tag] = [[VZSingleDirectoryShare alloc] initWithDirectory:source];
      }
      // Validate every request before replacing any attachment. Missing tags
      // revoke their share; reserved empty devices grant no host file access.
      for (NSString *tag in devices) devices[tag].share = shares[tag];
    } else if (![op isEqual:@"status"]) {
      reply(@{@"error": @"Unsupported runtime operation."}); return;
    }
    NSMutableArray *attached = [NSMutableArray array];
    for (NSString *tag in devices) {
      VZDirectoryShare *share = devices[tag].share;
      if ([share isKindOfClass:VZSingleDirectoryShare.class]) {
        VZSharedDirectory *source = ((VZSingleDirectoryShare *)share).directory;
        [attached addObject:@{@"tag": tag, @"path": source.URL.path, @"read_only": @(source.readOnly)}];
      }
    }
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    reply(@{@"pid": @(getpid()), @"runtime": @"custom", @"protocol": @1,
      @"saving": @(saving), @"state": @(machine.state),
      @"features": @[@"live-shares", @"independent-audio", @"save-restore", @"live-ui"], @"shares": attached,
      @"ui_enabled": @(SMControlEnabled()),
      @"audio_output": @([env[@"SECOND_MAC_AUDIO_OUTPUT"] isEqual:@"1"]),
      @"microphone": @([env[@"SECOND_MAC_MICROPHONE"] isEqual:@"1"])});
  });
}
