// Drag planning adapted from Cua's foreground_drag_events (MIT).
// Copyright (c) 2025 Cua AI, Inc. See ../third-party/CUA-LICENSE.txt.
// Upstream: trycua/cua, c1c2b5fee428c3a39bebe5e77549c3d3525a608d,
// libs/cua-driver/rust/crates/platform-macos/src/input/mouse.rs.
// Keep the move/down/interpolated-drag/up contract; transport is guest-only VZ.
#import <Foundation/Foundation.h>
#import <math.h>

static NSDictionary *SMPointerStep(double x, double y, NSInteger buttons, double at) {
  return @{@"x":@(x), @"y":@(y), @"buttons":@(buttons), @"at":@(at)};
}
static BOOL SMCoordinate(id x, id y) {
  return [x isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class] &&
      isfinite([x doubleValue]) && isfinite([y doubleValue]) &&
      [x doubleValue] >= 0 && [x doubleValue] < 1024 &&
      [y doubleValue] >= 0 && [y doubleValue] < 768;
}
static NSArray *SMPointerPlan(NSDictionary *c) {
  if (!SMCoordinate(c[@"x"], c[@"y"])) return nil;
  double x = [c[@"x"] doubleValue], y = [c[@"y"] doubleValue];
  NSMutableArray *steps = [NSMutableArray arrayWithObject:SMPointerStep(x, y, 0, 0)];
  NSString *op = c[@"op"];
  if ([op isEqual:@"move"]) return steps;
  if ([op isEqual:@"click"]) {
    NSNumber *button = @{@"left":@1, @"right":@2, @"middle":@4}[c[@"button"] ?: @"left"];
    id count = c[@"count"] ?: @1;
    if (!button || ![count isKindOfClass:NSNumber.class] || [count doubleValue] != [count integerValue] ||
        [count integerValue] < 1 || [count integerValue] > 3) return nil;
    for (NSInteger i = 0; i < [count integerValue]; i++) {
      [steps addObject:SMPointerStep(x, y, button.integerValue, 0.075 + i * 0.15)];
      [steps addObject:SMPointerStep(x, y, 0, 0.15 + i * 0.15)];
    }
    return steps;
  }
  if ([op isEqual:@"drag"]) {
    id duration = c[@"duration"];
    if (!SMCoordinate(c[@"to_x"], c[@"to_y"]) || ![duration isKindOfClass:NSNumber.class] ||
        !isfinite([duration doubleValue]) || [duration doubleValue] < 0.1 || [duration doubleValue] > 5) return nil;
    double toX = [c[@"to_x"] doubleValue], toY = [c[@"to_y"] doubleValue], seconds = [duration doubleValue];
    NSInteger samples = MAX(1, (NSInteger)ceil(seconds * 60));
    [steps addObject:SMPointerStep(x, y, 1, 0.075)];
    for (NSInteger i = 1; i <= samples; i++) {
      double t = (double)i / samples;
      [steps addObject:SMPointerStep(x + (toX - x) * t, y + (toY - y) * t, 1, 0.15 + seconds * t)];
    }
    [steps addObject:SMPointerStep(toX, toY, 0, 0.225 + seconds)];
    return steps;
  }
  if ([op isEqual:@"scroll"]) {
    id dx = c[@"dx"], dy = c[@"dy"];
    if (![dx isKindOfClass:NSNumber.class] || ![dy isKindOfClass:NSNumber.class] ||
        !isfinite([dx doubleValue]) || !isfinite([dy doubleValue]) ||
        fabs([dx doubleValue]) > 4096 || fabs([dy doubleValue]) > 4096) return nil;
    double distance = MAX(fabs([dx doubleValue]), fabs([dy doubleValue]));
    if (distance == 0) return nil;
    // Prime the pointer and split large wheel deltas, as in Cua's scroll input.
    NSInteger samples = MAX(1, (NSInteger)ceil(distance / 64));
    for (NSInteger i = 0; i < samples; i++) {
      [steps addObject:@{@"x":@(x), @"y":@(y), @"buttons":@0,
        @"dx":@(-[dx doubleValue] / samples), @"dy":@(-[dy doubleValue] / samples),
        @"at":@(0.075 + i * 0.03)}];
    }
    return steps;
  }
  return nil;
}
