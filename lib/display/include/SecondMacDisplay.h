#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>

// All calls are on the VM's main queue. The only capabilities are its own
// display, virtual keyboard and virtual pointing device.
void SMDisplayInitialize(VZVirtualMachine *machine);
void SMDisplayCommand(NSDictionary *command,
                      void (^completion)(NSDictionary *));
int SMStartControl(VZVirtualMachine *machine, NSString *directory);
int SMSetControlEnabled(VZVirtualMachine *machine, NSString *directory, BOOL enabled);
BOOL SMControlEnabled(void);
int SMStartHostSocket(NSString *directory, const char *path,
                     void (^handler)(NSDictionary *, void (^)(NSDictionary *)));
int SMStartRuntimeControl(VZVirtualMachine *machine, VZVirtualMachineConfiguration *configuration, NSString *directory);
