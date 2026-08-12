#import "bro_motion.h"

#import <objc/runtime.h>

#include <cmath>

const CGFloat kBroGlassTintAlpha = 0.18;
const CGFloat kBroGlassBorderWidth = 1.0;

NSColor* BroGlassTintColor(void) {
  return [[NSColor controlBackgroundColor]
      colorWithAlphaComponent:kBroGlassTintAlpha];
}

NSColor* BroGlassBorderColor(void) {
  return [NSColor separatorColor];
}

NSGlassEffectViewStyle BroGlassEffectStyle(void) {
  return NSGlassEffectViewStyleRegular;
}

BOOL BroShouldUseNativeGlass(void) {
  if (@available(macOS 26.0, *)) {
    NSString* forced = NSProcessInfo.processInfo.environment[
        @"BRO_FORCE_LEGACY_GLASS"];
    return forced.length == 0 || forced.boolValue == NO;
  }
  return NO;
}

namespace {

struct BroSpringValues {
  CGFloat stiffness;
  CGFloat damping;
  CGFloat mass;
};

BroSpringValues ValuesForPreset(BroSpringPreset preset) {
  switch (preset) {
    case BroSpringText:
      return {100.0, 10.0, 1.0};
    case BroSpringTextTight:
      return {250.0, 22.0, 1.0};
    case BroSpringInteractive:
      return {900.0, 54.0, 1.0};
    case BroSpringLayout:
      return {380.0, 31.0, 1.0};
    case BroSpringOverlay:
      return {550.0, 42.0, 1.0};
  }
  return {900.0, 54.0, 1.0};
}

void SetLayerFrameWithoutActions(CALayer* layer, CGRect frame) {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.frame = frame;
  [CATransaction commit];
}

void AddScalarSpring(CALayer* layer,
                     NSString* keyPath,
                     CGFloat delta,
                     BroSpringPreset preset,
                     NSString* animationKey) {
  if (fabs(delta) < 0.01) {
    [layer removeAnimationForKey:animationKey];
    return;
  }
  CASpringAnimation* spring = BroSpringForKeyPath(keyPath, preset);
  spring.additive = YES;
  spring.fromValue = @(delta);
  spring.toValue = @0.0;
  [layer addAnimation:spring forKey:animationKey];
}

CATransform3D TopAnchoredScale(NSView* view, CGFloat scale) {
  CGFloat x = NSWidth(view.bounds) / 2.0;
  CGFloat y = NSHeight(view.bounds);
  CATransform3D transform = CATransform3DMakeTranslation(x, y, 0.0);
  transform = CATransform3DScale(transform, scale, scale, 1.0);
  return CATransform3DTranslate(transform, -x, -y, 0.0);
}

static const void* kBroOverlayGenerationKey = &kBroOverlayGenerationKey;

NSUInteger NextOverlayGeneration(NSView* view) {
  NSNumber* current = objc_getAssociatedObject(view, kBroOverlayGenerationKey);
  NSUInteger generation = current.unsignedIntegerValue + 1;
  objc_setAssociatedObject(view, kBroOverlayGenerationKey, @(generation),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return generation;
}

BOOL OverlayGenerationIsCurrent(NSView* view, NSUInteger generation) {
  NSNumber* current = objc_getAssociatedObject(view, kBroOverlayGenerationKey);
  return current.unsignedIntegerValue == generation;
}

void FadeLayerTo(CALayer* layer,
                 CGFloat targetOpacity,
                 CFTimeInterval duration,
                 NSString* key) {
  CALayer* presentation = (CALayer*)layer.presentationLayer;
  CGFloat from = presentation ? presentation.opacity : layer.opacity;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.opacity = targetOpacity;
  [CATransaction commit];
  CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
  fade.fromValue = @(from);
  fade.toValue = @(targetOpacity);
  fade.duration = duration;
  fade.timingFunction =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
  [layer addAnimation:fade forKey:key];
}

}  // namespace

BOOL BroMotionReduced(void) {
  return [NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;
}

CASpringAnimation* BroSpringForKeyPath(NSString* keyPath,
                                       BroSpringPreset preset) {
  BroSpringValues values = ValuesForPreset(preset);
  CASpringAnimation* spring = [CASpringAnimation animationWithKeyPath:keyPath];
  spring.stiffness = values.stiffness;
  spring.damping = values.damping;
  spring.mass = values.mass;
  spring.initialVelocity = 0.0;
  // Core Animation otherwise uses its short default and clips the tail.
  spring.duration = spring.settlingDuration;
  return spring;
}

void BroSpringRetargetPosition(CALayer* layer,
                               CGPoint target,
                               BroSpringPreset preset,
                               NSString* animationKey) {
  if (!layer) {
    return;
  }
  CALayer* presentation = (CALayer*)layer.presentationLayer;
  CGPoint visible = presentation ? presentation.position : layer.position;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.position = target;
  [CATransaction commit];

  NSString* base = animationKey ?: @"bro.position";
  if (BroMotionReduced()) {
    [layer removeAnimationForKey:[base stringByAppendingString:@".x"]];
    [layer removeAnimationForKey:[base stringByAppendingString:@".y"]];
    return;
  }
  AddScalarSpring(layer, @"position.x", visible.x - target.x, preset,
                  [base stringByAppendingString:@".x"]);
  AddScalarSpring(layer, @"position.y", visible.y - target.y, preset,
                  [base stringByAppendingString:@".y"]);
}

void BroSpringRetargetLayerFrame(CALayer* layer,
                                 CGRect target,
                                 BroSpringPreset preset,
                                 NSString* animationKey) {
  if (!layer) {
    return;
  }
  CALayer* presentation = (CALayer*)layer.presentationLayer;
  CGPoint visiblePosition = presentation ? presentation.position : layer.position;
  CGSize visibleSize = presentation ? presentation.bounds.size : layer.bounds.size;
  SetLayerFrameWithoutActions(layer, target);
  CGPoint targetPosition = layer.position;
  CGSize targetSize = layer.bounds.size;

  NSString* base = animationKey ?: @"bro.frame";
  if (BroMotionReduced()) {
    for (NSString* suffix in @[ @".x", @".y", @".w", @".h" ]) {
      [layer removeAnimationForKey:[base stringByAppendingString:suffix]];
    }
    return;
  }
  AddScalarSpring(layer, @"position.x", visiblePosition.x - targetPosition.x,
                  preset, [base stringByAppendingString:@".x"]);
  AddScalarSpring(layer, @"position.y", visiblePosition.y - targetPosition.y,
                  preset, [base stringByAppendingString:@".y"]);
  AddScalarSpring(layer, @"bounds.size.width", visibleSize.width - targetSize.width,
                  preset, [base stringByAppendingString:@".w"]);
  AddScalarSpring(layer, @"bounds.size.height", visibleSize.height - targetSize.height,
                  preset, [base stringByAppendingString:@".h"]);
}

void BroSpringRetargetFrame(NSView* view,
                            NSRect target,
                            BroSpringPreset preset,
                            NSString* animationKey) {
  if (!view) {
    return;
  }
  view.wantsLayer = YES;
  CALayer* layer = view.layer;
  CALayer* presentation = (CALayer*)layer.presentationLayer;
  CGPoint visiblePosition = presentation ? presentation.position : layer.position;
  CGSize visibleSize = presentation ? presentation.bounds.size : layer.bounds.size;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  view.frame = target;
  [CATransaction commit];
  CGPoint targetPosition = layer.position;
  CGSize targetSize = layer.bounds.size;

  NSString* base = animationKey ?: @"bro.view-frame";
  if (BroMotionReduced()) {
    for (NSString* suffix in @[ @".x", @".y", @".w", @".h" ]) {
      [layer removeAnimationForKey:[base stringByAppendingString:suffix]];
    }
    return;
  }
  AddScalarSpring(layer, @"position.x", visiblePosition.x - targetPosition.x,
                  preset, [base stringByAppendingString:@".x"]);
  AddScalarSpring(layer, @"position.y", visiblePosition.y - targetPosition.y,
                  preset, [base stringByAppendingString:@".y"]);
  AddScalarSpring(layer, @"bounds.size.width", visibleSize.width - targetSize.width,
                  preset, [base stringByAppendingString:@".w"]);
  AddScalarSpring(layer, @"bounds.size.height", visibleSize.height - targetSize.height,
                  preset, [base stringByAppendingString:@".h"]);
}

void BroRunLayoutSpring(void (^changes)(void),
                        void (^completion)(void)) {
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
    context.duration = BroMotionReduced() ? 0.0 : 0.35;
    if (!BroMotionReduced()) {
      context.timingFunction = [CAMediaTimingFunction
          functionWithControlPoints:0.3 :1.35 :0.4 :1.0];
    }
    if (changes) {
      changes();
    }
  } completionHandler:completion];
}

void BroApplyElevation(NSView* view, BroElevation elevation) {
  if (!view) {
    return;
  }
  view.wantsLayer = YES;
  CALayer* layer = view.layer;
  layer.masksToBounds = NO;
  layer.shadowColor = [NSColor blackColor].CGColor;

  switch (elevation) {
    case BroElevationBase:
      layer.backgroundColor = [NSColor blackColor].CGColor;
      layer.borderWidth = 1.0;
      layer.borderColor =
          [NSColor colorWithWhite:0x11 / 255.0 alpha:1.0].CGColor;
      layer.shadowOpacity = 0.0;
      break;
    case BroElevationRaised:
      layer.shadowOpacity = 0.0;
      break;
    case BroElevationOverlay:
    case BroElevationPanel:
      layer.backgroundColor =
          [NSColor colorWithWhite:0.18 alpha:0.96].CGColor;
      layer.borderWidth = kBroGlassBorderWidth;
      layer.borderColor = BroGlassBorderColor().CGColor;
      layer.shadowOffset = elevation == BroElevationOverlay
                               ? CGSizeMake(0.0, -2.0)
                               : CGSizeMake(0.0, -4.0);
      layer.shadowRadius =
          elevation == BroElevationOverlay ? 12.0 : 24.0;
      layer.shadowOpacity =
          elevation == BroElevationOverlay ? 0.35 : 0.45;
      break;
  }
}

// Glass surface: the elevation's flat fill is replaced by glass while border
// and shadow stay on the panel's own layer. On macOS 26 the controls live in
// NSGlassEffectView.contentView, the only hierarchy for which AppKit promises
// correct placement relative to the native effect. Older systems use a
// sibling host above the established HUD blur + adaptive tint.
// Constraint-pinned rather than autoresized: panels are typically created at
// NSZeroRect and sized on first show, and autoresizing from a zero-size
// superview leaves the surface or content host with stale geometry.
static void BroPinView(NSView* view, NSView* panel) {
  view.translatesAutoresizingMaskIntoConstraints = NO;
  [panel addSubview:view];
  [NSLayoutConstraint activateConstraints:@[
    [view.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
    [view.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
    [view.topAnchor constraintEqualToAnchor:panel.topAnchor],
    [view.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
  ]];
}

@interface BroAdaptiveGlassTintView : NSView
@end

@implementation BroAdaptiveGlassTintView
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.backgroundColor = BroGlassTintColor().CGColor;
  }
  return self;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  self.layer.backgroundColor = BroGlassTintColor().CGColor;
}
@end

NSView* BroInstallShellSurface(NSView* panel, CGFloat cornerRadius) {
  if (!panel) {
    return nil;
  }
  panel.wantsLayer = YES;
  panel.layer.backgroundColor = [NSColor clearColor].CGColor;
  CGFloat backdropRadius = BroCornerRadiusForSize(
      BroNestedCornerRadius(cornerRadius, 0.0), panel.bounds.size);

  if (@available(macOS 26.0, *)) {
    if (BroShouldUseNativeGlass()) {
      NSGlassEffectView* glass =
          [[NSGlassEffectView alloc] initWithFrame:panel.bounds];
      glass.cornerRadius = backdropRadius;
      glass.style = BroGlassEffectStyle();
      glass.tintColor = nil;
      NSView* contentHost = [[NSView alloc] initWithFrame:glass.bounds];
      contentHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      glass.contentView = contentHost;
      BroPinView(glass, panel);
      return contentHost;
    }
  }
  NSVisualEffectView* backdrop =
      [[NSVisualEffectView alloc] initWithFrame:panel.bounds];
  backdrop.material = NSVisualEffectMaterialHUDWindow;
  backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  backdrop.state = NSVisualEffectStateActive;
  backdrop.wantsLayer = YES;
  backdrop.layer.cornerRadius = backdropRadius;
  backdrop.layer.cornerCurve = kCACornerCurveContinuous;
  backdrop.layer.masksToBounds = YES;
  BroPinView(backdrop, panel);

  // Pre-26 fallback tone follows the selected/system appearance.
  NSView* tint =
      [[BroAdaptiveGlassTintView alloc] initWithFrame:panel.bounds];
  tint.layer.cornerRadius = backdropRadius;
  tint.layer.cornerCurve = kCACornerCurveContinuous;
  tint.layer.masksToBounds = YES;
  BroPinView(tint, panel);

  NSView* contentHost = [[NSView alloc] initWithFrame:panel.bounds];
  contentHost.wantsLayer = YES;
  contentHost.layer.backgroundColor = [NSColor clearColor].CGColor;
  contentHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  BroPinView(contentHost, panel);
  return contentHost;
}

NSView* BroInstallGlassSurface(NSView* panel, CGFloat cornerRadius) {
  if (!panel) {
    return nil;
  }
  panel.wantsLayer = YES;
  panel.layer.backgroundColor = [NSColor clearColor].CGColor;
  CGFloat backdropRadius = BroCornerRadiusForSize(
      BroNestedCornerRadius(cornerRadius, 0.0), panel.bounds.size);
  NSView* contentHost = [[NSView alloc] initWithFrame:panel.bounds];
  contentHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  contentHost.wantsLayer = YES;
  contentHost.layer.backgroundColor = [NSColor clearColor].CGColor;
  if (@available(macOS 26.0, *)) {
    if (BroShouldUseNativeGlass()) {
      NSGlassEffectView* glass =
          [[NSGlassEffectView alloc] initWithFrame:panel.bounds];
      glass.cornerRadius = backdropRadius;
      glass.style = BroGlassEffectStyle();
      glass.tintColor = nil;
      // Regular glass supplies its own adaptive edge. A fixed white hairline
      // would defeat that treatment on light backgrounds.
      panel.layer.borderWidth = 0.0;
      panel.layer.borderColor = [NSColor clearColor].CGColor;
      glass.contentView = contentHost;
      BroPinView(glass, panel);
      return contentHost;
    }
  }
  NSVisualEffectView* glass =
      [[NSVisualEffectView alloc] initWithFrame:panel.bounds];
  glass.material = NSVisualEffectMaterialHUDWindow;
  glass.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  glass.state = NSVisualEffectStateActive;
  glass.wantsLayer = YES;
  glass.layer.cornerRadius = backdropRadius;
  glass.layer.masksToBounds = YES;
  BroPinView(glass, panel);
  NSView* tint =
      [[BroAdaptiveGlassTintView alloc] initWithFrame:panel.bounds];
  tint.layer.cornerRadius = backdropRadius;
  tint.layer.masksToBounds = YES;
  BroPinView(tint, panel);
  // Add last so fallback controls stay above both the material and tint.
  BroPinView(contentHost, panel);
  return contentHost;
}

NSView* BroGlassContainerForContentView(NSView* contentView,
                                        CGFloat spacing) {
  if (!contentView) {
    return nil;
  }
  if (@available(macOS 26.0, *)) {
    if (BroShouldUseNativeGlass()) {
      NSGlassEffectContainerView* container =
          [[NSGlassEffectContainerView alloc]
              initWithFrame:contentView.frame];
      container.spacing = MAX(0.0, spacing);
      container.contentView = contentView;
      return container;
    }
  }
  return contentView;
}

void BroOverlayShow(NSView* view) {
  if (!view) {
    return;
  }
  NSUInteger generation = NextOverlayGeneration(view);
  (void)generation;
  view.wantsLayer = YES;
  CALayer* layer = view.layer;
  BOOL wasHidden = view.hidden;
  CALayer* presentation = (CALayer*)layer.presentationLayer;
  CGFloat visibleOpacity = wasHidden ? 0.0
                                     : (presentation ? presentation.opacity
                                                     : layer.opacity);
  CATransform3D visibleTransform =
      wasHidden ? TopAnchoredScale(view, 0.98)
                : (presentation ? presentation.transform : layer.transform);

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  view.hidden = NO;
  view.alphaValue = 1.0;
  layer.transform = CATransform3DIdentity;
  [CATransaction commit];
  [layer removeAnimationForKey:@"bro.overlay.hide.opacity"];

  if (BroMotionReduced()) {
    [layer removeAnimationForKey:@"bro.overlay.show.opacity"];
    [layer removeAnimationForKey:@"bro.overlay.show.transform"];
    return;
  }

  CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
  fade.fromValue = @(visibleOpacity);
  fade.toValue = @1.0;
  fade.duration = 0.12;
  fade.timingFunction =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
  [layer addAnimation:fade forKey:@"bro.overlay.show.opacity"];

  CASpringAnimation* scale =
      BroSpringForKeyPath(@"transform", BroSpringOverlay);
  scale.fromValue = [NSValue valueWithCATransform3D:visibleTransform];
  scale.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
  [layer addAnimation:scale forKey:@"bro.overlay.show.transform"];
}

void BroOverlayHide(NSView* view) {
  if (!view || view.hidden) {
    return;
  }
  NSUInteger generation = NextOverlayGeneration(view);
  view.wantsLayer = YES;
  CALayer* layer = view.layer;
  if (BroMotionReduced()) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.alphaValue = 1.0;
    view.hidden = YES;
    layer.transform = CATransform3DIdentity;
    [CATransaction commit];
    return;
  }

  CALayer* presentation = (CALayer*)layer.presentationLayer;
  CGFloat from = presentation ? presentation.opacity : layer.opacity;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  view.alphaValue = 0.0;
  [CATransaction commit];

  CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
  fade.fromValue = @(from);
  fade.toValue = @0.0;
  fade.duration = 0.12;
  fade.timingFunction =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
  [layer addAnimation:fade forKey:@"bro.overlay.hide.opacity"];

  // A transaction completion attached before addAnimation would run
  // immediately, so use the animation's duration as the generation-guarded
  // hide boundary.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(0.12 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (OverlayGenerationIsCurrent(view, generation)) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      view.hidden = YES;
      view.alphaValue = 1.0;
      layer.transform = CATransform3DIdentity;
      [CATransaction commit];
    }
  });
}

@implementation BroHoverHighlightGroup {
  __weak NSView* container_;
  __weak NSView* hoveredView_;
  CALayer* highlightLayer_;
  NSUInteger dismissGeneration_;
}

- (instancetype)initWithContainerView:(NSView*)container {
  self = [super init];
  if (self) {
    container_ = container;
    container.wantsLayer = YES;
    highlightLayer_ = [CALayer layer];
    highlightLayer_.anchorPoint = CGPointZero;
    highlightLayer_.cornerRadius = BroCornerRadiusForSize(
        BroControlCornerRadius(), highlightLayer_.bounds.size);
    highlightLayer_.backgroundColor =
        [[NSColor labelColor] colorWithAlphaComponent:0.08].CGColor;
    highlightLayer_.opacity = 0.0;
    [container.layer insertSublayer:highlightLayer_ atIndex:0];
  }
  return self;
}

- (void)hoverOnView:(NSView*)view {
  [self hoverOnView:view animated:YES];
}

- (void)hoverOnView:(NSView*)view animated:(BOOL)animated {
  NSView* container = container_;
  if (!container || !view || !view.superview) {
    return;
  }
  // CALayer stores a resolved CGColor, so refresh it at interaction time in
  // case the app's explicit/system appearance changed while the group rested.
  highlightLayer_.backgroundColor =
      [[NSColor labelColor] colorWithAlphaComponent:0.08].CGColor;
  dismissGeneration_++;
  BOOL wasVisible = highlightLayer_.opacity > 0.001 ||
                    ((CALayer*)highlightLayer_.presentationLayer).opacity > 0.001;
  CGRect target = [container convertRect:view.bounds fromView:view];
  hoveredView_ = view;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  highlightLayer_.cornerRadius = BroCornerRadiusForSize(
      BroControlCornerRadius(), target.size);
  [CATransaction commit];

  if (!animated || BroMotionReduced() || !wasVisible) {
    SetLayerFrameWithoutActions(highlightLayer_, target);
  } else {
    BroSpringRetargetLayerFrame(highlightLayer_, target,
                                BroSpringInteractive,
                                @"bro.hover-highlight.frame");
  }

  if (!wasVisible) {
    if (!animated || BroMotionReduced()) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      highlightLayer_.opacity = 1.0;
      [CATransaction commit];
    } else {
      FadeLayerTo(highlightLayer_, 1.0, 0.12,
                  @"bro.hover-highlight.opacity");
    }
  } else {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    highlightLayer_.opacity = 1.0;
    [CATransaction commit];
  }
}

- (void)hoverOffView:(NSView*)view {
  if (view && hoveredView_ != view) {
    return;
  }
  NSUInteger generation = ++dismissGeneration_;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(0.08 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (generation != self->dismissGeneration_) {
      return;
    }
    self->hoveredView_ = nil;
    if (BroMotionReduced()) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      self->highlightLayer_.opacity = 0.0;
      [CATransaction commit];
    } else {
      FadeLayerTo(self->highlightLayer_, 0.0, 0.12,
                  @"bro.hover-highlight.opacity");
    }
  });
}

- (void)dismissImmediately {
  dismissGeneration_++;
  hoveredView_ = nil;
  [highlightLayer_ removeAllAnimations];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  highlightLayer_.opacity = 0.0;
  [CATransaction commit];
}

@end
