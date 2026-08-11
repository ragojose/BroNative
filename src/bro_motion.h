// Native motion and surface primitives shared by Bro's AppKit chrome.

#ifndef BRO_MOTION_H_
#define BRO_MOTION_H_

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, BroSpringPreset) {
  BroSpringText,
  BroSpringTextTight,
  BroSpringInteractive,
  BroSpringLayout,
  BroSpringOverlay,
};

typedef NS_ENUM(NSInteger, BroElevation) {
  BroElevationBase,
  BroElevationRaised,
  BroElevationOverlay,
  BroElevationPanel,
};

// The single accessibility gate for all non-essential chrome motion.
extern BOOL BroMotionReduced(void);

// A configured spring whose duration includes its full settling tail.
extern CASpringAnimation* BroSpringForKeyPath(NSString* keyPath,
                                              BroSpringPreset preset);

// Interruption-safe, additive retargeting. The model is moved to the target
// without actions, then the presentation-to-target delta springs to zero.
extern void BroSpringRetargetPosition(CALayer* layer,
                                      CGPoint target,
                                      BroSpringPreset preset,
                                      NSString* animationKey);
extern void BroSpringRetargetLayerFrame(CALayer* layer,
                                        CGRect target,
                                        BroSpringPreset preset,
                                        NSString* animationKey);
extern void BroSpringRetargetFrame(NSView* view,
                                   NSRect target,
                                   BroSpringPreset preset,
                                   NSString* animationKey);

// Frame-driven layout spring. AppKit's animator continues to call the view's
// incremental frame setters, which keeps pill contents centered mid-resize.
extern void BroRunLayoutSpring(void (^changes)(void),
                               void (^completion)(void));

extern void BroApplyElevation(NSView* view, BroElevation elevation);
extern void BroOverlayShow(NSView* view);
extern void BroOverlayHide(NSView* view);

// A single highlight layer shared by adjacent interactive views. The short
// exit grace lets it spring between neighbors instead of blinking out/in.
@interface BroHoverHighlightGroup : NSObject
- (instancetype)initWithContainerView:(NSView*)container;
- (void)hoverOnView:(NSView*)view;
- (void)hoverOnView:(NSView*)view animated:(BOOL)animated;
- (void)hoverOffView:(NSView*)view;
- (void)dismissImmediately;
@end

#endif  // BRO_MOTION_H_
