// Shared geometry primitives for Bro's AppKit surfaces.

#ifndef BRO_GEOMETRY_H_
#define BRO_GEOMETRY_H_

#import <Cocoa/Cocoa.h>

// Corner radii follow the concentric-corner rule throughout the app:
//
//   outer radius - gap = inner radius
//
// Nested surfaces derive their curve from the boundary around them instead
// of repeating visually similar magic numbers. Standalone surfaces establish
// the outer radius; capsules derive theirs from their own height.
// https://cloudfour.com/thinks/the-math-behind-nesting-rounded-corners/
static inline CGFloat BroNestedCornerRadius(CGFloat outerRadius, CGFloat gap) {
  return MAX(0.0, outerRadius - MAX(0.0, gap));
}

static inline CGFloat BroCapsuleCornerRadius(CGFloat height) {
  return height / 2.0;
}

static const CGFloat kSurfaceCornerRadius = 8.0;
static const CGFloat kControlCornerGap = 2.0;
static const CGFloat kControlCornerRadius =
    BroNestedCornerRadius(kSurfaceCornerRadius, kControlCornerGap);
static const CGFloat kCompactControlCornerRadius =
    BroNestedCornerRadius(kControlCornerRadius, kControlCornerGap);

#endif  // BRO_GEOMETRY_H_
