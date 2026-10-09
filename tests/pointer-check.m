#import "../lib/display/Pointer.h"
#import <Virtualization/Virtualization.h>
@interface NSObject (ScrollProbe)
- (id)initWithScrollingDeltaX:(double)x scrollingDeltaY:(double)y
    acceleratedScrollingDeltaX:(double)ax acceleratedScrollingDeltaY:(double)ay
    scrollPhase:(NSUInteger)phase momentumPhase:(NSUInteger)momentum;
- (double)scrollingDeltaX;
- (double)scrollingDeltaY;
@end
static void check(BOOL value, NSString *name) {
  if (!value) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); exit(1); }
}
int main(void) {
  @autoreleasepool {
    NSArray *drag = SMPointerPlan(@{@"op":@"drag",@"x":@10,@"y":@20,@"to_x":@800,@"to_y":@600,@"duration":@0.6});
    check(drag.count > 5, @"drag has intermediate movement");
    check([drag.firstObject[@"buttons"] integerValue] == 0 && [drag[1][@"buttons"] integerValue] == 1, @"move precedes press");
    double lastTime = -1, lastX = 10;
    for (NSUInteger i=0; i<drag.count; i++) {
      NSDictionary *step = drag[i];
      check([step[@"at"] doubleValue] > lastTime, @"ordered event times");
      check([step[@"x"] doubleValue] >= lastX, @"monotone movement");
      if (i>0 && i<drag.count-1) check([step[@"buttons"] integerValue] == 1, @"button stays held through drag");
      lastTime = [step[@"at"] doubleValue]; lastX = [step[@"x"] doubleValue];
    }
    NSDictionary *last = drag.lastObject;
    check([last[@"buttons"] integerValue] == 0 && [last[@"x"] doubleValue] == 800 && [last[@"y"] doubleValue] == 600, @"release at destination");
    NSArray *click = SMPointerPlan(@{@"op":@"click",@"x":@10,@"y":@20,@"button":@"right",@"count":@2});
    check(click.count == 5 && [click[1][@"buttons"] integerValue] == 2 && [click[3][@"buttons"] integerValue] == 2 && [click.lastObject[@"buttons"] integerValue] == 0, @"two right clicks finish released");
    NSArray *scroll = SMPointerPlan(@{@"op":@"scroll",@"x":@10,@"y":@20,@"dx":@0,@"dy":@350});
    double total = 0;
    for (NSDictionary *step in scroll) { total += [step[@"dy"] doubleValue]; check([step[@"buttons"] integerValue] == 0, @"scroll never clicks"); }
    check(fabs(total + 350) < 0.001, @"scroll preserves distance and native direction");
    check(!SMPointerPlan(@{@"op":@"move",@"x":@1024,@"y":@20}), @"offscreen target rejected");
    check(!SMPointerPlan(@{@"op":@"drag",@"x":@10,@"y":@20,@"to_x":@100,@"to_y":@200,@"duration":@(NAN)}), @"invalid duration rejected");
    // Construct a real VZ event without posting anything to host or guest.
    (void)[VZVirtualMachine class];
    Class wheel = NSClassFromString(@"_VZScrollWheelEvent");
    check(wheel != Nil, @"native wheel event available");
    id event = [[wheel alloc] initWithScrollingDeltaX:-12.5 scrollingDeltaY:48.5
        acceleratedScrollingDeltaX:-12.5 acceleratedScrollingDeltaY:48.5 scrollPhase:0 momentumPhase:0];
    check([event scrollingDeltaX] == -12.5 && [event scrollingDeltaY] == 48.5, @"native wheel preserves both axes");
    puts("Pointer gesture checks passed.");
  }
}
