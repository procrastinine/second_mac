#import <Foundation/Foundation.h>

enum { SMKeyDefaultHoldMS = 80, SMKeyMinHoldMS = 10, SMKeyMaxHoldMS = 5000 };
// Main-queue, bounded press. Completion runs after all releases are attempted,
// even if the requesting socket disconnects or a device send throws.
BOOL SMKeyHoldValid(id value);
BOOL SMKeyboardBusy(void);
BOOL SMBeginKeyboardPause(void);
void SMEndKeyboardPause(void);
void SMPressKey(unsigned short code, NSUInteger flags, NSInteger holdMS,
    void (^send)(unsigned short, BOOL), void (^completion)(BOOL));
