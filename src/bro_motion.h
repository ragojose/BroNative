// Native motion and surface primitives shared by Bro's AppKit chrome.

#ifndef BRO_MOTION_H_
#define BRO_MOTION_H_

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#import "bro_geometry.h"

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

// Shared material tokens for bounded glass surfaces. macOS 26 uses untinted
// Regular glass; older systems retain an appearance-adaptive HUD fallback.
extern const CGFloat kBroGlassTintAlpha;
extern const CGFloat kBroGlassBorderWidth;
extern NSColor* BroGlassTintColor(void);
extern NSColor* BroGlassBorderColor(void);
extern NSGlassEffectViewStyle BroGlassEffectStyle(void)
    API_AVAILABLE(macos(26.0));
// Runtime gate shared by native control and overlay surfaces.
// BRO_FORCE_LEGACY_GLASS=1 is a test seam for exercising the macOS 12–25
// fallback on a macOS 26 machine.
extern BOOL BroShouldUseNativeGlass(void);

// Installs the stable window-sized AppKit backdrop. The shell deliberately
// stays non-lensing at every OS version because a full-window
// NSGlassEffectView corrupts its backing texture on large Retina windows;
// bounded controls and overlays still use native Liquid Glass on macOS 26.
extern NSView* BroInstallShellSurface(NSView* panel, CGFloat cornerRadius);

// Replaces the elevation's flat fill with the shared glass surface and
// returns the host that must own the surface's controls. On macOS 26 this is
// the native glass view's contentView; older systems use a sibling host above
// the existing HUD blur + tint.
// Call after BroApplyElevation and add all visible content to the result.
extern NSView* BroInstallGlassSurface(NSView* panel, CGFloat cornerRadius);
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
