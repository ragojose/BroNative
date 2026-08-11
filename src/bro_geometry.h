// Shared geometry primitives for Bro's AppKit surfaces.

#ifndef BRO_GEOMETRY_H_
#define BRO_GEOMETRY_H_

#import <Cocoa/Cocoa.h>

// The system-resolved shell radius is the root of the app's concentric-corner
// hierarchy. Every non-capsule surface derives from the boundary above it:
//
//   outer radius - gap = inner radius
//
// Nested surfaces derive their curve from the boundary around them instead
// of establishing independent radii. Capsules derive theirs from their own
// height because their curve is intrinsic rather than nested.
// https://cloudfour.com/thinks/the-math-behind-nesting-rounded-corners/
static inline CGFloat BroNestedCornerRadius(CGFloat outerRadius, CGFloat gap) {
  return MAX(0.0, outerRadius - MAX(0.0, gap));
}

static inline CGFloat BroCapsuleCornerRadius(CGFloat height) {
  return height / 2.0;
}

// Core Animation accepts radii larger than half a layer's shortest edge, but
// its corner arcs then overlap and produce pointed/diamond-like shapes. Keep
// the shell-derived preferred radius while enforcing the geometric limit of
// the element that will render it. A zero-sized view is usually awaiting its
// first layout, so preserve the preferred radius until it has real bounds.
static inline CGFloat BroCornerRadiusForSize(CGFloat preferredRadius,
                                             NSSize size) {
  CGFloat shortestEdge = MIN(size.width, size.height);
  if (shortestEdge <= 0.0) {
    return MAX(0.0, preferredRadius);
  }
  return MIN(MAX(0.0, preferredRadius), shortestEdge / 2.0);
}

// Used until the window frame is available. BroShellCornerRadius is updated
// from AppKit's real NSThemeFrame radius before chrome views are constructed.
static const CGFloat kShellCornerRadiusFallback = 12.0;
static const CGFloat kShellCornerRadiusReduction = 2.0;
extern CGFloat BroShellCornerRadius(void);

static const CGFloat kShellSurfaceCornerGap = 4.0;
static const CGFloat kControlCornerGap = 2.0;
// AppKit can expose a much larger shell radius for some window styles. The
// hierarchy still derives from that root, but each smaller component level
// has a design-scale ceiling so compact controls remain rounded rectangles
// rather than inflating into circles.
static const CGFloat kSurfaceCornerRadiusMaximum = 12.0;
static const CGFloat kControlCornerRadiusMaximum = 8.0;
static const CGFloat kCompactControlCornerRadiusMaximum = 6.0;

static inline CGFloat BroSurfaceCornerRadius(void) {
  return MIN(kSurfaceCornerRadiusMaximum,
             BroNestedCornerRadius(BroShellCornerRadius(),
                                   kShellSurfaceCornerGap));
}

static inline CGFloat BroControlCornerRadius(void) {
  return MIN(kControlCornerRadiusMaximum,
             BroNestedCornerRadius(BroSurfaceCornerRadius(),
                                   kControlCornerGap));
}

static inline CGFloat BroCompactControlCornerRadius(void) {
  return MIN(kCompactControlCornerRadiusMaximum,
             BroNestedCornerRadius(BroControlCornerRadius(),
                                   kControlCornerGap));
}

#endif  // BRO_GEOMETRY_H_
