// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <QuartzCore/QuartzCore.h>

#include <cmath>
#include <cstdlib>

#include "bro_handler.h"
#import "bro_mac_internal.h"
#import "bro_motion.h"
#import "bro_text_morph.h"
#import "radix_icons.h"

// The active pill shares the same glass as its neighbors; a brighter
// hairline is its primary structural selection cue.
static const CGFloat kActiveTabBorderAlpha = 0.28;
static const CGFloat kHoveredTabBorderAlpha = 0.18;
static const CFTimeInterval kTabColorTransitionDuration = 0.18;

static NSDictionary* BroTabLayerTransitionActions(void) {
  NSMutableDictionary* actions = [BroLayerTransitionActions() mutableCopy];
  for (NSString* key in @[ @"borderColor", @"backgroundColor" ]) {
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:key];
    fade.duration = kTabColorTransitionDuration;
    fade.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    actions[key] = fade;
  }
  return actions;
}

// Scales about the view's center regardless of the layer's anchorPoint.
// AppKit pins layer-backed views' anchorPoint to (0,0) and reasserts it on
// layout, so the pivot is baked into the transform instead. Used only by
// BroHoverButton below.
static CATransform3D BroCenteredScale(NSView* view, CGFloat scale) {
  if (scale == 1.0) {
    return CATransform3DIdentity;
  }
  CGFloat w = NSWidth(view.bounds);
  CGFloat h = NSHeight(view.bounds);
  CATransform3D t = CATransform3DMakeTranslation(w / 2.0, h / 2.0, 0);
  t = CATransform3DScale(t, scale, scale, 1.0);
  return CATransform3DTranslate(t, -w / 2.0, -h / 2.0, 0);
}

// AppKit may make a clicked pill first responder before delivering its
// mouseDown:. That focus is pointer-driven and must not trigger the immediate
// preview reserved for keyboard traversal.
static BOOL BroCurrentEventIsPointerActivation(void) {
  NSEventType type = NSApp.currentEvent.type;
  return type == NSEventTypeLeftMouseDown ||
         type == NSEventTypeRightMouseDown ||
         type == NSEventTypeOtherMouseDown;
}

#pragma mark - BroHoverButton

NSString* BroShortcutDisplayString(NSString* keyEquivalent,
                                   NSEventModifierFlags modifierMask) {
  if (keyEquivalent.length == 0) {
    return @"";
  }
  NSMutableString* display = [NSMutableString string];
  if (modifierMask & NSEventModifierFlagControl) [display appendString:@"⌃"];
  if (modifierMask & NSEventModifierFlagOption) [display appendString:@"⌥"];
  if (modifierMask & NSEventModifierFlagShift) [display appendString:@"⇧"];
  if (modifierMask & NSEventModifierFlagCommand) [display appendString:@"⌘"];
  NSString* key = keyEquivalent.uppercaseString;
  if ([keyEquivalent isEqualToString:@"\e"]) {
    key = @"Esc";
  } else if ([keyEquivalent
                 isEqualToString:[NSString stringWithFormat:@"%C",
                                                            (unichar)NSLeftArrowFunctionKey]]) {
    key = @"←";
  } else if ([keyEquivalent
                 isEqualToString:[NSString stringWithFormat:@"%C",
                                                            (unichar)NSRightArrowFunctionKey]]) {
    key = @"→";
  } else if ([keyEquivalent
                 isEqualToString:[NSString stringWithFormat:@"%C",
                                                            (unichar)NSPageUpFunctionKey]]) {
    key = @"Page Up";
  } else if ([keyEquivalent
                 isEqualToString:[NSString stringWithFormat:@"%C",
                                                            (unichar)NSPageDownFunctionKey]]) {
    key = @"Page Down";
  }
  [display appendString:key];
  return display;
}

static NSString* BroSpokenShortcutString(NSString* keyEquivalent,
                                         NSEventModifierFlags modifierMask) {
  NSMutableArray<NSString*>* parts = [NSMutableArray array];
  if (modifierMask & NSEventModifierFlagControl) [parts addObject:@"Control"];
  if (modifierMask & NSEventModifierFlagOption) [parts addObject:@"Option"];
  if (modifierMask & NSEventModifierFlagShift) [parts addObject:@"Shift"];
  if (modifierMask & NSEventModifierFlagCommand) [parts addObject:@"Command"];
  NSString* key = keyEquivalent.uppercaseString;
  if ([keyEquivalent isEqualToString:@"["]) {
    key = @"Left Bracket";
  } else if ([keyEquivalent isEqualToString:@"]"]) {
    key = @"Right Bracket";
  } else if ([keyEquivalent isEqualToString:@"\e"]) {
    key = @"Escape";
  } else if ([keyEquivalent
                 isEqualToString:[NSString stringWithFormat:@"%C",
                                                            (unichar)NSLeftArrowFunctionKey]]) {
    key = @"Left Arrow";
  } else if ([keyEquivalent
                 isEqualToString:[NSString stringWithFormat:@"%C",
                                                            (unichar)NSRightArrowFunctionKey]]) {
    key = @"Right Arrow";
  } else if ([keyEquivalent
                 isEqualToString:[NSString stringWithFormat:@"%C",
                                                            (unichar)NSPageUpFunctionKey]]) {
    key = @"Page Up";
  } else if ([keyEquivalent
                 isEqualToString:[NSString stringWithFormat:@"%C",
                                                            (unichar)NSPageDownFunctionKey]]) {
    key = @"Page Down";
  }
  if (key.length > 0) {
    [parts addObject:key];
  }
  return [parts componentsJoinedByString:@"-"];
}

BOOL BroEventMatchesShortcut(NSEvent* event,
                             NSString* keyEquivalent,
                             NSEventModifierFlags modifierMask) {
  if (event.type != NSEventTypeKeyDown || keyEquivalent.length == 0) {
    return NO;
  }
  NSEventModifierFlags relevant =
      NSEventModifierFlagControl | NSEventModifierFlagOption |
      NSEventModifierFlagShift | NSEventModifierFlagCommand;
  NSEventModifierFlags actual =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
      relevant;
  if (actual != (modifierMask & relevant)) {
    return NO;
  }
  return [event.charactersIgnoringModifiers.lowercaseString
      isEqualToString:keyEquivalent.lowercaseString];
}

// BroHoverButton's @interface is declared in bro_mac_internal.h (shared
// with the toolbar, downloads popover, tab search panel, and tab strip).
@implementation BroHoverButton {
  BOOL hovered_;
  BOOL pressed_;
  BOOL focused_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.cornerRadius =
        BroCornerRadiusForSize(BroControlCornerRadius(), self.bounds.size);
    self.layer.actions = BroLayerTransitionActions();
    // Keyboard focus shows as the same gray hairline the tab pills use, not
    // the system's accent-colored ring.
    self.focusRingType = NSFocusRingTypeNone;
    NSTrackingArea* trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:trackingArea];
  }
  return self;
}

- (BOOL)acceptsFirstResponder {
  return self.enabled;
}

- (BOOL)canBecomeKeyView {
  return self.enabled && !self.hiddenOrHasHiddenAncestor;
}

- (void)refreshBorder {
  if (focused_) {
    self.layer.borderColor = BroControlBorderColor().CGColor;
    self.layer.borderWidth = 1.0;
  } else {
    self.layer.borderColor = _baseBorderColor.CGColor;
    self.layer.borderWidth = _baseBorderWidth;
  }
}

- (void)setBaseBorderWidth:(CGFloat)width {
  _baseBorderWidth = width;
  [self refreshBorder];
}

- (void)setBaseBorderColor:(NSColor*)color {
  _baseBorderColor = color;
  [self refreshBorder];
}

- (BOOL)becomeFirstResponder {
  // Compound controls can reveal themselves before AppKit commits focus, so
  // an alpha-hidden button is never the invisible first responder.
  if (_focusChangedHandler) {
    _focusChangedHandler(self, YES);
  }
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    focused_ = YES;
    [self refreshBorder];
  } else if (_focusChangedHandler) {
    _focusChangedHandler(self, NO);
  }
  return ok;
}

- (BOOL)resignFirstResponder {
  BOOL ok = [super resignFirstResponder];
  if (ok) {
    focused_ = NO;
    [self refreshBorder];
    if (_focusChangedHandler) {
      _focusChangedHandler(self, NO);
    }
  }
  return ok;
}

- (void)configureActionLabel:(NSString*)label
               keyEquivalent:(NSString*)keyEquivalent
                modifierMask:(NSEventModifierFlags)modifierMask {
  NSString* actionLabel = label.length > 0 ? label : @"Action";
  _shortcutKeyEquivalent = [keyEquivalent copy] ?: @"";
  _shortcutModifierMask = modifierMask;
  self.accessibilityLabel = actionLabel;
  NSString* display =
      BroShortcutDisplayString(_shortcutKeyEquivalent, modifierMask);
  self.toolTip = display.length > 0
      ? [NSString stringWithFormat:@"%@ (%@)", actionLabel, display]
      : actionLabel;
  NSString* spoken =
      BroSpokenShortcutString(_shortcutKeyEquivalent, modifierMask);
  self.accessibilityHelp = spoken.length > 0
      ? [NSString stringWithFormat:@"Keyboard shortcut: %@.", spoken]
      : nil;
}

// Hover/pressed feedback layers over a persistent selected background for
// toggle/radio controls such as the viewport buttons.
- (void)refreshBackground {
  CGFloat alpha = 0.0;
  if (pressed_) {
    alpha = 0.16;
  } else if (_selectedState) {
    alpha = (self.enabled && hovered_ && !_highlightGroup) ? 0.14 : 0.10;
  } else if (self.enabled && hovered_ && !_highlightGroup) {
    alpha = 0.08;
  }
  self.layer.backgroundColor =
      alpha > 0
          ? [[NSColor labelColor] colorWithAlphaComponent:alpha].CGColor
          : [NSColor clearColor].CGColor;
}

// Single funnel for the hover/press scale, mirroring refreshBackground.
// Disabled buttons and Reduce Motion users get no motion.
- (void)refreshTransform {
  CGFloat scale = 1.0;
  if (self.enabled && !BroMotionReduced()) {
    if (pressed_) {
      scale = kIconPressScale;
    } else if (hovered_ && !_highlightGroup) {
      scale = kIconHoverScale;
    }
  }
  self.layer.transform = BroCenteredScale(self, scale);
}

- (void)setSelectedState:(BOOL)selectedState {
  _selectedState = selectedState;
  self.accessibilityValue = @(selectedState);
  [self refreshBackground];
}

- (void)setEnabled:(BOOL)enabled {
  if (!enabled && self.enabled && hovered_) {
    [_highlightGroup hoverOffView:self];
    if (_hoverChangedHandler) {
      _hoverChangedHandler(self, NO);
    }
    hovered_ = NO;
    pressed_ = NO;
  }
  [super setEnabled:enabled];
  [self refreshBackground];
  [self refreshTransform];
  // Disabled buttons show the plain arrow cursor, not the pointing hand.
  [self.window invalidateCursorRectsForView:self];
}

// The scale pivot is baked from bounds, so a resize while hovered must
// recompute it or the scale drifts off-center.
- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self refreshTransform];
}

// A button hidden mid-hover (the tab ✕, mode switches) never gets
// mouseExited:; reset so it reappears at rest.
- (void)viewDidHide {
  [super viewDidHide];
  BOOL wasHovered = hovered_;
  hovered_ = NO;
  pressed_ = NO;
  [_highlightGroup hoverOffView:self];
  if (wasHovered && _hoverChangedHandler) {
    _hoverChangedHandler(self, NO);
  }
  [self refreshBackground];
  [self refreshTransform];
}

- (void)resetCursorRects {
  if (self.enabled) {
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
  }
}

- (void)mouseEntered:(NSEvent*)event {
  if (!self.enabled) {
    return;
  }
  hovered_ = YES;
  [_highlightGroup hoverOnView:self];
  if (_hoverChangedHandler) {
    _hoverChangedHandler(self, YES);
  }
  [self refreshBackground];
  [self refreshTransform];
}

- (void)mouseExited:(NSEvent*)event {
  hovered_ = NO;
  pressed_ = NO;
  [_highlightGroup hoverOffView:self];
  if (_hoverChangedHandler) {
    _hoverChangedHandler(self, NO);
  }
  [self refreshBackground];
  [self refreshTransform];
}

- (void)mouseDown:(NSEvent*)event {
  if (!self.enabled) {
    return;
  }
  pressed_ = YES;
  [self refreshBackground];
  [self refreshTransform];
  // Runs the tracking loop synchronously; returns after mouse-up.
  [super mouseDown:event];
  pressed_ = NO;
  [self refreshBackground];
  [self refreshTransform];
}

- (void)keyDown:(NSEvent*)event {
  if (BroEventMatchesShortcut(event, _shortcutKeyEquivalent,
                              _shortcutModifierMask)) {
    [self performClick:self];
    return;
  }
  NSString* chars = event.charactersIgnoringModifiers;
  unichar c = chars.length > 0 ? [chars characterAtIndex:0] : 0;
  if (c == ' ' || c == '\r' || c == NSEnterCharacter) {
    [self performClick:self];
    return;
  }
  [super keyDown:event];
}

@end

#pragma mark - BroTabView

// BroTabView's @interface is declared in bro_mac_internal.h (shared with the
// toolbar). BroTabBar's @interface is declared there too (shared with
// bro_tabsearch.mm).

// BroFetchFaviconGuarded is declared extern in bro_mac_internal.h.
void BroFetchFaviconGuarded(NSString* urlString,
                             NSUInteger generation,
                             BOOL (^stillCurrent)(NSUInteger generation),
                             void (^applyImage)(NSImage* image)) {
  [[BroFaviconLoader sharedLoader]
      fetchFavicon:urlString
        completion:^(NSImage* image) {
    if (image && stillCurrent(generation)) {
      applyImage(image);
    }
  }];
}

@implementation BroTabView {
  // macOS 12–25 keep the active browse input's established HUD glass. On
  // macOS 26+ the whole toolbar is one Regular glass surface, so a nested
  // pill surface would be glass-on-glass and is deliberately omitted.
  NSView* glassBackdrop_;
  BOOL hovered_;
  BOOL focused_;
  // Target state of the trailing action fade; guards against the many
  // updateAppearance callers restarting an in-flight fade.
  BOOL trailingActionShown_;
  BOOL trailingActionShowsPin_;
  BOOL trailingActionFocused_;
  // Bumped on every setFaviconURL:; a fetch completion only applies its image
  // if the generation still matches, so a slow response for a previous page
  // can't overwrite the current page's favicon. Main-thread only.
  NSUInteger faviconGeneration_;
  // The built-in globe follows tab selection color; downloaded favicons keep
  // their authored colors instead of being flattened to a template tint.
  BOOL showingDefaultFavicon_;
}

- (instancetype)initWithFrame:(NSRect)frame browserId:(int)browserId {
  self = [super initWithFrame:frame];
  if (self) {
    _browserId = browserId;
    _isActive = NO;
    _isLoading = NO;
    _tabURL = @"";

    self.wantsLayer = YES;
    CGFloat pillCornerRadius =
        BroCornerRadiusForSize(BroSurfaceCornerRadius(), self.bounds.size);
    self.layer.cornerRadius = pillCornerRadius;
    self.layer.borderWidth = 1.0;
    self.layer.actions = BroTabLayerTransitionActions();
    // Keyboard focus shows as an adaptive pill border instead of the system's
    // accent-colored ring.
    self.focusRingType = NSFocusRingTypeNone;

    // Older systems retain the active pill's HUD surface. Regular Liquid
    // Glass on macOS 26+ belongs to the toolbar host instead, with this pill
    // communicating selection through an adaptive fill and hairline.
    if (@available(macOS 26.0, *)) {
      glassBackdrop_ = nil;
    } else {
      NSVisualEffectView* glass =
          [[NSVisualEffectView alloc] initWithFrame:self.bounds];
      glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      glass.material = NSVisualEffectMaterialHUDWindow;
      glass.blendingMode = NSVisualEffectBlendingModeWithinWindow;
      glass.state = NSVisualEffectStateActive;
      glass.wantsLayer = YES;
      glass.layer.cornerRadius =
          BroNestedCornerRadius(pillCornerRadius, 0.0);
      glass.layer.cornerCurve = kCACornerCurveContinuous;
      glass.layer.masksToBounds = YES;

      glassBackdrop_ = glass;
    }
    if (glassBackdrop_) {
      glassBackdrop_.hidden = YES;
      [self addSubview:glassBackdrop_];
    }

    // Favicon view
    _faviconView = [[NSImageView alloc]
        initWithFrame:NSMakeRect(10, (kTabPillHeight - 15) / 2.0, 15, 15)];
    _faviconView.wantsLayer = YES;
    _faviconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _faviconView.accessibilityElement = NO;
    // Default globe icon
    _faviconView.image = RadixIconImage(RadixIconGlobe, 15);
    _faviconView.contentTintColor = BroPlaceholderFaviconColor();
    showingDefaultFavicon_ = YES;
    [self addSubview:_faviconView];

    // The host remains authoritative while loading; its shimmer is the one
    // loading treatment, so the favicon never swaps to a second animation.
    _titleLabel = [[BroShimmerTextView alloc]
        initWithFont:BroUIFont(kTabTextFontSize)
                 color:[NSColor labelColor]];
    _titleLabel.frame = NSMakeRect(
        32, (kTabPillHeight - kTabTextFrameHeight) / 2.0,
        frame.size.width - 32 - 26, kTabTextFrameHeight);
    [_titleLabel setText:kBroBlankTabTitle];
    _titleLabel.autoresizingMask = NSViewWidthSizable;
    [self addSubview:_titleLabel];

    // Trailing tab action: normal tabs show close; pinned tabs reuse the same
    // slot and hover behavior for unpin.
    BroHoverButton* closeButton = [[BroHoverButton alloc]
        initWithFrame:NSMakeRect(frame.size.width - 26,
                                 (kTabPillHeight - 16) / 2.0, 16, 16)];
    closeButton.bezelStyle = NSBezelStyleTexturedRounded;
    closeButton.bordered = NO;
    closeButton.title = @"";
    closeButton.image = RadixIconImage(RadixIconCross2, 10);
    closeButton.imagePosition = NSImageOnly;
    closeButton.contentTintColor = [NSColor tertiaryLabelColor];
    // The close control is concentric with the pill: its 16pt square sits
    // evenly inside the 28pt pill, leaving a 6pt gap on both horizontal
    // edges. 8 - 6 = 2.
    CGFloat closeButtonGap =
        (kTabPillHeight - NSHeight(closeButton.frame)) / 2.0;
    closeButton.layer.cornerRadius = BroCornerRadiusForSize(
        BroNestedCornerRadius(pillCornerRadius, closeButtonGap),
        closeButton.bounds.size);
    closeButton.target = self;
    closeButton.action = @selector(handleClose:);
    closeButton.autoresizingMask = NSViewMinXMargin;
    [closeButton configureActionLabel:@"Close Tab"
                        keyEquivalent:@"w"
                         modifierMask:NSEventModifierFlagCommand];
    __weak BroTabView* weakSelf = self;
    closeButton.focusChangedHandler =
        ^(BroHoverButton* button, BOOL focused) {
      BroTabView* strongSelf = weakSelf;
      if (!strongSelf) {
        return;
      }
      strongSelf->trailingActionFocused_ = focused;
      [strongSelf updateAppearance];
    };
    _closeButton = closeButton;
    // Start hidden to match trailingActionShown_'s NO default.
    _closeButton.hidden = YES;
    [self addSubview:_closeButton];

    [self updateAppearance];

    // Add tracking area for hover
    NSTrackingArea* trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:trackingArea];
  }
  return self;
}

- (void)setFaviconURL:(NSString*)urlString {
  if (!urlString || urlString.length == 0) return;
  _faviconURL = [urlString copy];

  NSUInteger generation = ++faviconGeneration_;
  __weak BroTabView* weakSelf = self;
  BroFetchFaviconGuarded(
      urlString, generation,
      ^BOOL(NSUInteger g) {
        BroTabView* strongSelf = weakSelf;
        return strongSelf && strongSelf->faviconGeneration_ == g;
      },
      ^(NSImage* image) {
        BroTabView* strongSelf = weakSelf;
        strongSelf->showingDefaultFavicon_ = NO;
        strongSelf.faviconView.image = image;
        strongSelf.faviconView.contentTintColor = nil;
      });
}

- (void)setTabURL:(NSString*)url {
  NSString* newURL = [url copy] ?: @"";
  if (![_tabURL isEqualToString:newURL]) {
    // The cached meta description belongs to the old page.
    _pageDescription = nil;
  }
  _tabURL = newURL;
  NSString* display = BroURLIsBlank(_tabURL)
                          ? kBroBlankTabTitle
                          : BroDisplayHostForURL(_tabURL);
  [_titleLabel setText:display];
}

// Single place deciding what the pill shows at its current width: normally the
// favicon sits at the left inset with text beside it; collapsed, the favicon
// centers and the host label steps aside.
- (void)layoutPillContents {
  BOOL compactPinned =
      _pinned && self.bounds.size.width >= kPinnedTabPillWidth - 0.5;
  CGFloat iconX = (_iconOnly && !compactPinned)
                      ? (self.bounds.size.width - 15) / 2.0
                      : 10.0;
  NSRect iconFrame = NSMakeRect(iconX, (kTabPillHeight - 15) / 2.0, 15, 15);
  _faviconView.frame = iconFrame;
  CGFloat actionX = self.bounds.size.width - 26.0;
  _closeButton.frame = NSMakeRect(
      actionX, (self.bounds.size.height - 16.0) / 2.0, 16.0, 16.0);
  // Text runs from the favicon's right edge to just inside the ✕ (or the
  // pill's edge when there is no room for one). Clamped at zero so a collapsed
  // pill can't produce a negative width.
  CGFloat textRight = (_closable || _pinned) ? 26.0 : 10.0;
  NSRect textFrame =
      NSMakeRect(32,
                 (self.bounds.size.height - kTabTextFrameHeight) / 2.0,
                 MAX(0.0, self.bounds.size.width - 32 - textRight),
                 kTabTextFrameHeight);
  // Commit frame and visibility together so neither Core Animation nor
  // AppKit gets an intermediate frame mid state change.
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _titleLabel.frame = textFrame;
  _titleLabel.hidden = _iconOnly;
  [CATransaction commit];
}

- (void)setIconOnly:(BOOL)iconOnly {
  if (_iconOnly == iconOnly) {
    return;
  }
  _iconOnly = iconOnly;
  [self layoutPillContents];
}

// Width changes arrive through the animator during layout, so re-centre the
// favicon as the pill resizes rather than only at the end.
- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self layoutPillContents];
}

- (void)setLoading:(BOOL)loading {
  if (_isLoading == loading) {
    return;  // Repeated events must not restart the shimmer sweep.
  }
  _isLoading = loading;
  _titleLabel.loading = loading;
}

- (void)applyDefaultFaviconColor:(NSColor*)color {
  if (!showingDefaultFavicon_ ||
      [_faviconView.contentTintColor isEqual:color]) {
    return;
  }
  if (self.window != nil && !BroMotionReduced()) {
    CATransition* fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = kTabColorTransitionDuration;
    fade.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_faviconView.layer addAnimation:fade forKey:@"bro.tab.favicon-color"];
  }
  _faviconView.contentTintColor = color;
}

// Pills share the toolbar's Regular glass on macOS 26+. Selection is
// communicated through adaptive content, border contrast, and a restrained
// translucent fill; older systems retain the active pill's HUD backdrop.
- (void)updateAppearance {
  [CATransaction begin];
  [CATransaction setDisableActions:BroMotionReduced()];
  BOOL usesAdaptiveToolbarGlass = NO;
  if (@available(macOS 26.0, *)) {
    usesAdaptiveToolbarGlass = YES;
  }
  if (_isActive) {
    glassBackdrop_.hidden = _dropTarget;
    self.layer.backgroundColor =
        usesAdaptiveToolbarGlass
            ? [[NSColor labelColor] colorWithAlphaComponent:0.08].CGColor
            : [NSColor clearColor].CGColor;
    self.layer.borderColor =
        [[NSColor labelColor]
            colorWithAlphaComponent:kActiveTabBorderAlpha].CGColor;
    self.layer.borderWidth = kBroGlassBorderWidth;
    NSColor* foreground = [NSColor labelColor];
    _titleLabel.color = foreground;
    [self applyDefaultFaviconColor:foreground];
  } else {
    glassBackdrop_.hidden = _dropTarget;
    self.layer.backgroundColor = [NSColor clearColor].CGColor;
    BOOL emphasizeBorder = _isSplitPane || hovered_ || focused_;
    CGFloat borderAlpha =
        emphasizeBorder ? kHoveredTabBorderAlpha : 0.05;
    self.layer.borderColor =
        [[NSColor labelColor] colorWithAlphaComponent:borderAlpha].CGColor;
    NSColor* foreground = [NSColor secondaryLabelColor];
    _titleLabel.color = foreground;
    [self applyDefaultFaviconColor:foreground];
  }
  // A dragged pill hovering this one (drop = split the two tabs) outshines
  // every other state so the target is unmistakable.
  if (_dropTarget) {
    glassBackdrop_.hidden = YES;
    self.layer.backgroundColor =
        [[NSColor labelColor] colorWithAlphaComponent:0.14].CGColor;
    self.layer.borderColor =
        [[NSColor labelColor] colorWithAlphaComponent:0.6].CGColor;
  }
  [CATransaction commit];
  // The same trailing control closes a normal tab or unpins a pinned one.
  // Close remains visible on the active tab; unpin is deliberately revealed
  // only on hover/focus so the pin state does not compete with the favicon.
  if (trailingActionShowsPin_ != _pinned) {
    trailingActionShowsPin_ = _pinned;
    _closeButton.image = RadixIconImage(
        _pinned ? RadixIconDrawingPinFilled : RadixIconCross2, 10);
    _closeButton.action = _pinned ? @selector(handleUnpin:)
                                  : @selector(handleClose:);
    [_closeButton configureActionLabel:(_pinned ? @"Unpin Tab" : @"Close Tab")
                          keyEquivalent:(_pinned ? @"p" : @"w")
                           modifierMask:(_pinned
                               ? NSEventModifierFlagCommand |
                                     NSEventModifierFlagOption
                               : NSEventModifierFlagCommand)];
  }
  BOOL showAction = _pinned
      ? (hovered_ || focused_ || trailingActionFocused_)
      : (_closable && (_isActive || hovered_ || focused_ ||
                       trailingActionFocused_));
  [self setTrailingActionShown:showAction];
}

// Fades the close/unpin action in/out instead of snapping.
- (void)setTrailingActionShown:(BOOL)shown {
  if (shown == trailingActionShown_) {
    return;
  }
  trailingActionShown_ = shown;
  // Pills built off-window (init-time updateAppearance) must not fade in.
  BOOL animate =
      self.window != nil && !BroMotionReduced();
  if (!animate) {
    _closeButton.hidden = !shown;
    _closeButton.alphaValue = 1.0;
    return;
  }
  if (shown) {
    // May be mid fade-out; unhide and retarget from the current alpha.
    BOOL wasHidden = _closeButton.hidden;
    _closeButton.hidden = NO;
    if (wasHidden) {
      _closeButton.alphaValue = 0.0;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = kCloseButtonFadeDuration;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseOut];
      self->_closeButton.animator.alphaValue = 1.0;
    }];
  } else {
    __weak BroTabView* weakSelf = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = kCloseButtonFadeDuration;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseOut];
      self->_closeButton.animator.alphaValue = 0.0;
    } completionHandler:^{
      BroTabView* strongSelf = weakSelf;
      // Only hide if a re-show hasn't retargeted the fade meanwhile.
      if (strongSelf && !strongSelf->trailingActionShown_) {
        strongSelf->_closeButton.hidden = YES;
      }
    }];
  }
}

- (void)setClosable:(BOOL)closable {
  _closable = closable;
  [self updateAppearance];
  // Text width depends on whether a ✕ is reserving space.
  [self layoutPillContents];
}

- (void)setPinned:(BOOL)pinned {
  if (_pinned == pinned) {
    return;
  }
  _pinned = pinned;
  [self updateAppearance];
  [self layoutPillContents];
}

- (void)setIsActive:(BOOL)isActive {
  _isActive = isActive;
  [self updateAppearance];
  [self layoutPillContents];
}

- (void)setDropTarget:(BOOL)dropTarget {
  _dropTarget = dropTarget;
  [self refreshCorners];
  [self updateAppearance];
}

- (void)setIsSplitPane:(BOOL)isSplitPane {
  _isSplitPane = isSplitPane;
  [self updateAppearance];
}

- (void)setJoinedSide:(NSInteger)joinedSide {
  _joinedSide = joinedSide;
  [self refreshCorners];
}

// Corner shape is derived state: a joined pill squares its meeting corners,
// but a drag-over drop target rounds back to a full pill so it matches its
// bright standalone highlight (and restores the joined shape when the drag
// moves off). maskedCorners is a discrete property Core Animation can't
// interpolate — the shared layer actions don't cover it — so shape changes
// crossfade via a CATransition instead of snapping mid-slide.
- (void)refreshCorners {
  CACornerMask all = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner |
                     kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
  CACornerMask mask = all;
  if (!_dropTarget && _joinedSide == 1) {
    mask = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
  } else if (!_dropTarget && _joinedSide == 2) {
    mask = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
  }
  if (self.layer.maskedCorners == mask) {
    return;
  }
  if (self.window != nil && !BroMotionReduced()) {
    CATransition* fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = kCloseButtonFadeDuration;
    fade.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.layer addAnimation:fade forKey:@"cornerShape"];
  }
  self.layer.maskedCorners = mask;
  glassBackdrop_.layer.maskedCorners = mask;
}

- (void)performSelect {
  if (_target && _selectAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [_target performSelector:_selectAction withObject:self];
#pragma clang diagnostic pop
  }
}

// The pills sit in the full-size-content title bar region, where AppKit's
// default is to treat a drag as a window move and never deliver mouseDragged:
// to the view. The pill runs its own reorder drag, so it opts out.
- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

// The pill owns its whole surface, so it can be picked up anywhere. Without
// this, the title label (and the favicon and spinner) swallow the gesture and
// only the active tab can be dragged.
- (NSView*)hitTest:(NSPoint)point {
  NSView* hit = [super hitTest:point];
  if (!hit) {
    return nil;
  }
  // The close button keeps its own clicks.
  if (hit == _closeButton || [hit isDescendantOf:_closeButton]) {
    return hit;
  }
  return self;
}

// Switching tabs happens on mouse-down (like real browsers). Any pill can be
// picked up and dragged to reorder the strip; a plain click on the active
// pill does nothing further.
- (void)mouseDown:(NSEvent*)event {
  if (!_isActive) {
    [self performSelect];
  }
  if (_owningTabBar) {
    [_owningTabBar beginPotentialDragForTab:self withEvent:event];
  }
}

- (void)mouseDragged:(NSEvent*)event {
  if (_owningTabBar) {
    [_owningTabBar dragTab:self withEvent:event];
  }
}

- (void)mouseUp:(NSEvent*)event {
  if (_owningTabBar) {
    [_owningTabBar endDragForTab:self];
  }
}

// Middle-click closes the tab, like every other Chromium browser. It fires on
// release and only inside the pill, so sliding off cancels the way the ✕
// button already does. Going through handleClose: means a lone tab closes the
// window, exactly as Cmd+W does.
- (void)otherMouseDown:(NSEvent*)event {
  // Claim the middle press so AppKit routes its release here too; anything
  // else (mouse back/forward) keeps bubbling.
  if (event.buttonNumber != 2) {
    [super otherMouseDown:event];
  }
}

- (void)otherMouseUp:(NSEvent*)event {
  if (event.buttonNumber != 2) {
    [super otherMouseUp:event];
    return;
  }
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  if (NSPointInRect(p, self.bounds)) {
    [self handleClose:self];
  }
}

- (void)mouseEntered:(NSEvent*)event {
  hovered_ = YES;
  [self updateAppearance];
  if (_owningTabBar) {
    [_owningTabBar tabHoverBegan:self];
  }
}

- (void)mouseExited:(NSEvent*)event {
  hovered_ = NO;
  [self updateAppearance];
  if (_owningTabBar) {
    [_owningTabBar tabHoverEnded:self];
  }
}

#pragma mark Keyboard focus

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)canBecomeKeyView {
  return !self.hiddenOrHasHiddenAncestor;
}

- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    focused_ = YES;
    [self updateAppearance];
    if (!BroCurrentEventIsPointerActivation() && _owningTabBar) {
      [_owningTabBar tabFocusBegan:self];
    }
  }
  return ok;
}

- (BOOL)resignFirstResponder {
  BOOL ok = [super resignFirstResponder];
  if (ok) {
    focused_ = NO;
    [self updateAppearance];
    if (_owningTabBar) {
      [_owningTabBar tabFocusEnded:self];
    }
  }
  return ok;
}

- (void)keyDown:(NSEvent*)event {
  NSString* chars = event.charactersIgnoringModifiers;
  unichar c = chars.length > 0 ? [chars characterAtIndex:0] : 0;
  if (c == ' ' || c == '\r' || c == NSEnterCharacter) {
    [self performSelect];
    return;
  }
  if (c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey) {
    if (_owningTabBar) {
      [_owningTabBar focusTabRelativeTo:self
                                 offset:(c == NSRightArrowFunctionKey ? 1 : -1)];
      return;
    }
  }
  [super keyDown:event];
}

- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

#pragma mark Accessibility

// Pills read as the radio buttons of a tab group (how AppKit exposes native
// tab strips): label = host, value = selected.
- (BOOL)isAccessibilityElement {
  return YES;
}

- (NSString*)accessibilityRole {
  return NSAccessibilityRadioButtonRole;
}

- (NSString*)accessibilityRoleDescription {
  return @"tab";
}

- (NSString*)accessibilityLabel {
  NSString* host = _titleLabel.text;
  NSString* label = host.length > 0
      ? host
      : (self.pageTitle.length > 0 ? self.pageTitle : kBroBlankTabTitle);
  if (_pinned) {
    label = [label stringByAppendingString:@", pinned"];
  }
  // Announce split membership: sighted users see the joined pill and the two
  // panes, but this label is all VoiceOver gets. Left/right mirrors the pane
  // framing rule (strip order decides sides).
  BroHandler* handler = BroHandler::GetInstance();
  int active_id = handler ? handler->GetActiveBrowserId() : -1;
  int my_id = self.browserId;
  if (SplitActive() &&
      (my_id == active_id || my_id == g_split_browser_id)) {
    int partner = my_id == active_id ? g_split_browser_id : active_id;
    BOOL left = BroTabStripIndex(my_id) < BroTabStripIndex(partner);
    label = [label stringByAppendingString:left ? @", split screen left pane"
                                                : @", split screen right pane"];
  }
  return label;
}

- (id)accessibilityValue {
  return @(_isActive);
}

- (BOOL)accessibilityPerformPress {
  [self performSelect];
  return YES;
}

- (void)handleClose:(id)sender {
  if (_target && _closeAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [_target performSelector:_closeAction withObject:self];
#pragma clang diagnostic pop
  }
}

- (void)handleUnpin:(id)sender {
  if (_pinned && _owningTabBar) {
    [_owningTabBar togglePinForTab:self];
  }
}

@end

#pragma mark - BroTabHoverCard

// Floating glass card shown after dwelling on a tab pill: page title, display
// host, (when available) the page's meta description, and a row of tab
// actions (pin, split screen). Interactive — the tab bar keeps it alive for a
// grace period after the mouse leaves the pill so the buttons can be reached.
@interface BroTabHoverCard : NSView
// Tab actions; the tab bar sets target/action/icon/state on every show.
@property (nonatomic, strong) BroHoverButton* pinButton;
@property (nonatomic, strong) BroHoverButton* splitButton;
// The tab bar owning the hover lifecycle; told when the mouse enters/leaves
// the card so the grace-period hide can be canceled and re-armed.
@property (nonatomic, weak) BroTabBar* hoverDelegate;
// Populates the labels and resizes self to fit; caller positions the frame.
- (void)setTitle:(NSString*)title
             url:(NSString*)url
     pageDescription:(NSString*)desc
           width:(CGFloat)width;
@end

@implementation BroTabHoverCard {
  NSView* contentHost_;
  BroShimmerTextView* titleLabel_;
  NSTextField* urlLabel_;
  NSTextField* descriptionLabel_;
}

// BroHoverCardLabel is declared extern in bro_mac_internal.h.
NSTextField* BroHoverCardLabel(NSFont* font, CGFloat whiteAlpha) {
  NSTextField* label = [[NSTextField alloc] initWithFrame:NSZeroRect];
  label.editable = NO;
  label.selectable = NO;
  label.bezeled = NO;
  label.bordered = NO;
  label.drawsBackground = NO;
  label.font = font;
  label.textColor = whiteAlpha >= 0.8
                        ? [NSColor labelColor]
                        : (whiteAlpha >= 0.5
                               ? [NSColor secondaryLabelColor]
                               : [NSColor tertiaryLabelColor]);
  label.lineBreakMode = NSLineBreakByTruncatingTail;
  label.cell.truncatesLastVisibleLine = YES;
  return label;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.cornerRadius =
        BroCornerRadiusForSize(BroSurfaceCornerRadius(), self.bounds.size);
    BroApplyElevation(self, BroElevationOverlay);
    contentHost_ = BroInstallGlassSurface(self, self.layer.cornerRadius);

    self.accessibilityRole = NSAccessibilityGroupRole;
    self.accessibilityLabel = @"Tab preview";

    titleLabel_ = [[BroShimmerTextView alloc]
        initWithFont:BroUIFontBold(12.0) color:[NSColor labelColor]];
    urlLabel_ = BroHoverCardLabel(BroUIFont(11.0), 0.55);
    descriptionLabel_ = BroHoverCardLabel(BroUIFont(11.0), 0.75);
    descriptionLabel_.lineBreakMode = NSLineBreakByWordWrapping;
    descriptionLabel_.cell.wraps = YES;
    [contentHost_ addSubview:titleLabel_];
    [contentHost_ addSubview:urlLabel_];
    [contentHost_ addSubview:descriptionLabel_];

    _pinButton = [self makeActionButton];
    _splitButton = [self makeActionButton];

    // The buttons carry their own tracking areas, but they lie inside this
    // rect, so moving onto them never reads as leaving the card.
    NSTrackingArea* trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:trackingArea];
  }
  return self;
}

- (BroHoverButton*)makeActionButton {
  BroHoverButton* button = [[BroHoverButton alloc]
      initWithFrame:NSMakeRect(0, 0, kHoverCardButtonSize,
                               kHoverCardButtonSize)];
  button.bordered = NO;
  button.title = @"";
  button.imagePosition = NSImageOnly;
  button.contentTintColor = [NSColor labelColor];
  __weak BroTabHoverCard* weakSelf = self;
  button.focusChangedHandler = ^(BroHoverButton* focusedButton, BOOL focused) {
    BroTabHoverCard* card = weakSelf;
    if (focused) {
      [card.hoverDelegate cardHoverBegan];
    } else {
      [card.hoverDelegate cardHoverEnded];
    }
  };
  [contentHost_ addSubview:button];
  return button;
}

- (void)mouseEntered:(NSEvent*)event {
  [_hoverDelegate cardHoverBegan];
}

- (void)mouseExited:(NSEvent*)event {
  [_hoverDelegate cardHoverEnded];
}

- (void)setTitle:(NSString*)title
             url:(NSString*)url
     pageDescription:(NSString*)desc
           width:(CGFloat)width {
  const CGFloat padX = 12.0;
  const CGFloat padY = 10.0;
  const CGFloat rowGap = 3.0;
  const CGFloat textWidth = width - padX * 2;

  [titleLabel_ setText:title ?: @""];
  urlLabel_.stringValue = url ?: @"";
  descriptionLabel_.stringValue = desc ?: @"";
  descriptionLabel_.hidden = desc.length == 0;
  self.accessibilityLabel = title.length > 0
      ? [NSString stringWithFormat:@"Tab preview: %@", title]
      : @"Tab preview";

  CGFloat titleHeight = titleLabel_.desiredSize.height;
  CGFloat urlHeight = ceil([urlLabel_.cell cellSizeForBounds:
      NSMakeRect(0, 0, CGFLOAT_MAX, CGFLOAT_MAX)].height);

  CGFloat descriptionHeight = 0;
  if (!descriptionLabel_.hidden) {
    // Wrapped height at the card's width, capped at three lines.
    CGFloat lineHeight = ceil([descriptionLabel_.font ascender] -
                              [descriptionLabel_.font descender] +
                              [descriptionLabel_.font leading]);
    descriptionHeight = ceil([descriptionLabel_.cell cellSizeForBounds:
        NSMakeRect(0, 0, textWidth, CGFLOAT_MAX)].height);
    descriptionHeight = MIN(descriptionHeight, lineHeight * 3);
  }

  // Space between the text block and the action-button row beneath it.
  const CGFloat buttonRowGap = 8.0;

  CGFloat height = padY * 2 + titleHeight + rowGap + urlHeight +
                   buttonRowGap + kHoverCardButtonSize;
  if (descriptionHeight > 0) {
    height += rowGap + descriptionHeight;
  }

  // Flipped-less (default) coords: title on top, buttons at the bottom. The
  // buttons overhang padX slightly so their icons (not their hover
  // backgrounds) align with the text.
  CGFloat buttonX = padX - (kHoverCardButtonSize - 12.0) / 2.0;
  _pinButton.frame = NSMakeRect(buttonX, padY, kHoverCardButtonSize,
                                kHoverCardButtonSize);
  _splitButton.frame =
      NSMakeRect(buttonX + kHoverCardButtonSize + 8.0, padY,
                 kHoverCardButtonSize, kHoverCardButtonSize);

  CGFloat y = padY + kHoverCardButtonSize + buttonRowGap;
  if (descriptionHeight > 0) {
    descriptionLabel_.frame = NSMakeRect(padX, y, textWidth, descriptionHeight);
    y += descriptionHeight + rowGap;
  } else {
    descriptionLabel_.frame = NSZeroRect;
  }
  urlLabel_.frame = NSMakeRect(padX, y, textWidth, urlHeight);
  y += urlHeight + rowGap;
  titleLabel_.frame = NSMakeRect(padX, y, textWidth, titleHeight);

  [self setFrameSize:NSMakeSize(width, height)];
}

@end

#pragma mark - BroTabBar

// Scrolls only the pill document. The fixed New Tab and Search Tabs controls
// remain siblings in BroTabBar, so no amount of overflow can cover them.
@interface BroHorizontalTabScrollView : NSScrollView
@property (nonatomic, weak) BroTabBar* tabBar;
@end

@implementation BroHorizontalTabScrollView

- (void)scrollWheel:(NSEvent*)event {
  [_tabBar hideHoverCard];

  // Precision devices provide deltaX directly. Traditional mouse wheels do
  // not, so Shift+wheel maps their vertical delta onto the horizontal axis.
  if ((event.modifierFlags & NSEventModifierFlagShift) != 0 &&
      fabs(event.scrollingDeltaX) < fabs(event.scrollingDeltaY)) {
    NSClipView* clip = self.contentView;
    NSPoint origin = clip.bounds.origin;
    CGFloat multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 12.0;
    origin.x -= event.scrollingDeltaY * multiplier;
    CGFloat maxX = MAX(0.0, NSWidth(self.documentView.frame) -
                                NSWidth(clip.bounds));
    origin.x = MIN(MAX(0.0, origin.x), maxX);
    [clip scrollToPoint:origin];
    [self reflectScrolledClipView:clip];
    return;
  }
  [super scrollWheel:event];
}

@end

@implementation BroTabBar {
  BroHorizontalTabScrollView* tabScrollView_;
  NSView* tabContentView_;
  BroTabView* draggingTab_;
  BOOL dragging_;
  CGFloat dragStartX_;
  CGFloat dragOffsetX_;
  // Pill the dragged one is hovering over; releasing there splits the two
  // tabs instead of reordering.
  BroTabView* joinTargetTab_;
  BroTabHoverCard* hoverCard_;
  NSTimer* hoverCardTimer_;
  // Pending grace-period hide, armed when the mouse leaves the pill or the
  // card; canceled when it enters either.
  NSTimer* hoverCardHideTimer_;
  // Tab the visible card belongs to; -1 when hidden.
  int hoverCardTabId_;
  // When keyboard focus opens the card, splice its actions directly after the
  // focused pill (and its visible close button) in the key-view loop.
  __weak NSView* hoverCardKeyAnchor_;
  __weak NSView* hoverCardReturnKeyView_;
  __weak BroTabView* hoverCardSourceTab_;
  BOOL hidingHoverCard_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _tabs = [NSMutableArray array];
    _activeTabId = -1;
    hoverCardTabId_ = -1;
    self.autoresizingMask = NSViewWidthSizable;

    // Performance: Enable layer-backing for GPU compositing
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.layer.masksToBounds = YES;

    // Only the pills scroll. The document is widened by applyTabLayout: when
    // compact pills overflow, while the two controls below remain fixed.
    tabScrollView_ = [[BroHorizontalTabScrollView alloc]
        initWithFrame:NSMakeRect(0, 0, 0, frame.size.height)];
    tabScrollView_.tabBar = self;
    tabScrollView_.drawsBackground = NO;
    tabScrollView_.borderType = NSNoBorder;
    tabScrollView_.hasHorizontalScroller = NO;
    tabScrollView_.hasVerticalScroller = NO;
    tabScrollView_.horizontalScrollElasticity = NSScrollElasticityAutomatic;
    tabScrollView_.verticalScrollElasticity = NSScrollElasticityNone;
    tabScrollView_.automaticallyAdjustsContentInsets = NO;
    tabScrollView_.contentView.drawsBackground = NO;
    tabContentView_ =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 0, frame.size.height)];
    tabContentView_.wantsLayer = YES;
    tabScrollView_.documentView = tabContentView_;
    [self addSubview:tabScrollView_];

    // Borderless "+" control, pinned between the scroll viewport and Search.
    // It keeps the compact hit area and icon size used by the original strip.
    CGFloat addY = (frame.size.height - kAddTabButtonSize) / 2.0;
    _addTabButton = [[BroHoverButton alloc]
        initWithFrame:NSMakeRect(0, addY, kAddTabButtonSize, kAddTabButtonSize)];
    _addTabButton.bordered = NO;
    _addTabButton.title = @"";
    _addTabButton.image = RadixIconImage(RadixIconPlus, 10);
    _addTabButton.imagePosition = NSImageOnly;
    _addTabButton.contentTintColor = [NSColor labelColor];
    _addTabButton.layer.cornerRadius = BroCornerRadiusForSize(
        BroCompactControlCornerRadius(), _addTabButton.bounds.size);
    _addTabButton.target = self;
    _addTabButton.action = @selector(createNewTab:);
    [_addTabButton configureActionLabel:@"New Tab"
                          keyEquivalent:@"t"
                           modifierMask:NSEventModifierFlagCommand];
    [self addSubview:_addTabButton];

    // Palette search button, pinned at the strip's right edge. Sized and
    // styled like the toolbar buttons to its right — it reads as part of that
    // trailing cluster, and hides/reveals with the downloads button (the
    // toolbar owns the shared hover zone).
    _tabSearchButton = [[BroHoverButton alloc]
        initWithFrame:NSMakeRect(frame.size.width - kButtonSize,
                                 (frame.size.height - kButtonSize) / 2.0,
                                 kButtonSize, kButtonSize)];
    _tabSearchButton.bordered = NO;
    _tabSearchButton.title = @"";
    _tabSearchButton.image = RadixIconImage(RadixIconMagnifyingGlass, 15);
    _tabSearchButton.imagePosition = NSImageOnly;
    _tabSearchButton.contentTintColor = [NSColor labelColor];
    _tabSearchButton.target = self;
    _tabSearchButton.action = @selector(toggleTabSearch:);
    [_tabSearchButton configureActionLabel:@"Search Tabs"
                             keyEquivalent:@"a"
                              modifierMask:NSEventModifierFlagCommand |
                                           NSEventModifierFlagShift];
    _tabSearchButton.alphaValue = 0.0;
    [self addSubview:_tabSearchButton];

    [self applyTabLayout:NO];
  }
  return self;
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement {
  return YES;
}

- (NSString*)accessibilityRole {
  return NSAccessibilityTabGroupRole;
}

- (NSString*)accessibilityLabel {
  return @"Tabs";
}

- (void)createNewTab:(id)sender {
  CreateNewBrowserTab();
}

- (void)toggleTabSearch:(id)sender {
  ToggleCommandPalette(BroPaletteScopeTabs);
}

- (void)addTabWithBrowserId:(int)browserId title:(NSString*)title {
  CGFloat pillY = (self.frame.size.height - kTabPillHeight) / 2.0;
  BroTabView* tab = [[BroTabView alloc]
      initWithFrame:NSMakeRect(0, pillY, kTabPillMaxWidth, kTabPillHeight)
          browserId:browserId];
  tab.owningTabBar = self;
  tab.pageTitle = BroURLIsBlank(title) ? kBroBlankTabTitle : title;
  tab.target = self;
  tab.selectAction = @selector(tabSelected:);
  tab.closeAction = @selector(tabClosed:);
  [_tabs addObject:tab];
  [tabContentView_ addSubview:tab];

  // The new pill starts at its final slot fully transparent and fades in while
  // its neighbors slide over to make room.
  NSArray<NSNumber*>* widths = [self tabWidths];
  CGFloat tabX = 0.0;
  for (NSUInteger i = 0; i + 1 < _tabs.count; i++) {
    BroTabView* preceding = _tabs[i];
    tabX += widths[i].doubleValue -
            (preceding.joinedSide == 1 ? kSplitJoinedOverlap : -kTabGap);
  }
  CGFloat tabWidth = widths.lastObject.doubleValue;
  tab.frame = NSMakeRect(tabX, pillY, tabWidth, kTabPillHeight);
  tab.alphaValue = 0.0;
  BroRunLayoutSpring(^{
    [self applyTabLayout:YES];
  }, nil);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  tab.alphaValue = 1.0;
  [CATransaction commit];
  if (!BroMotionReduced()) {
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.0;
    fade.toValue = @1.0;
    fade.duration = 0.15;
    fade.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseOut];
    [tab.layer addAnimation:fade forKey:@"bro.tab.enter.opacity"];
    CASpringAnimation* scale =
        BroSpringForKeyPath(@"transform", BroSpringInteractive);
    scale.fromValue = [NSValue valueWithCATransform3D:
        BroCenteredScale(tab, 0.97)];
    scale.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    [tab.layer addAnimation:scale forKey:@"bro.tab.enter.transform"];
  }
  [self.window recalculateKeyViewLoop];
}

#pragma mark Drag to reorder

- (void)beginPotentialDragForTab:(BroTabView*)tab withEvent:(NSEvent*)event {
  [self hideHoverCard];
  NSPoint p = [tabContentView_ convertPoint:event.locationInWindow fromView:nil];
  draggingTab_ = tab;
  dragging_ = NO;
  dragStartX_ = p.x;
  dragOffsetX_ = p.x - tab.frame.origin.x;
}

- (void)dragTab:(BroTabView*)tab withEvent:(NSEvent*)event {
  if (tab != draggingTab_) {
    return;
  }
  NSPoint p = [tabContentView_ convertPoint:event.locationInWindow fromView:nil];
  if (!dragging_) {
    // A few points of slop separates a click from a drag.
    if (fabs(p.x - dragStartX_) < 4.0) {
      return;
    }
    dragging_ = YES;
    // The dragged pill rides above the pills it passes.
    tab.layer.zPosition = 10.0;
    // Closed hand for the duration of the carry. Cursor rects are suspended
    // so the pills we pass over can't reset it back to the arrow.
    [self.window disableCursorRects];
    [[NSCursor closedHandCursor] push];
  }
  // NSView's native edge autoscroll keeps distant slots reachable without a
  // separate timer. Convert again after it runs because the document origin
  // may have changed.
  [tabContentView_ autoscroll:event];
  p = [tabContentView_ convertPoint:event.locationInWindow fromView:nil];
  // AppKit still resets the cursor as the pointer crosses tracking areas, so
  // reassert it on every drag event.
  [[NSCursor closedHandCursor] set];

  CGFloat pillY = (self.frame.size.height - kTabPillHeight) / 2.0;
  // The carried pill keeps whatever width it already has (collapsed, it is the
  // expanded active one), while the slots it moves between are sized by the
  // pills it passes. Reordering never crosses the pinned/unpinned boundary:
  // the pill travels only its own group's slot range.
  CGFloat tabWidth = tab.frame.size.width;
  CGFloat slotWidth = [self dragSlotWidthForTab:tab];
  NSUInteger pinnedCount = [self pinnedCount];
  NSInteger groupStart = tab.pinned ? 0 : (NSInteger)pinnedCount;
  NSInteger groupEnd =
      tab.pinned ? (NSInteger)pinnedCount - 1 : (NSInteger)_tabs.count - 1;
  // Where the unpinned group starts, x-wise: past every pinned pill's slot.
  CGFloat groupOriginX = 0.0;
  if (!tab.pinned) {
    NSArray<NSNumber*>* widths = [self tabWidths];
    for (NSUInteger i = 0; i < pinnedCount; i++) {
      groupOriginX += widths[i].doubleValue + kTabGap;
    }
  }
  CGFloat maxX = groupOriginX + (CGFloat)(groupEnd - groupStart) * slotWidth;
  CGFloat newX = MIN(MAX(p.x - dragOffsetX_, groupOriginX), maxX);
  tab.frame = NSMakeRect(newX, pillY, tabWidth, kTabPillHeight);

  // Carrying the pill over a neighbor first offers a JOIN (drop there →
  // split the two tabs; the neighbor lights up); pushing on toward the far
  // edge of the neighbor's slot reorders as before. `delta` is how far the
  // pill has traveled from its own slot, in slots: past 0.5 it overlaps the
  // neighbor (join zone), past 0.9 it has all but displaced it (reorder).
  NSInteger current = [_tabs indexOfObject:tab];
  if (current == NSNotFound) {
    // The close is deferred (dispatch_async, to avoid re-entering CEF), so it
    // can land between two mouseDragged: events of a live drag and pull the
    // pill out of _tabs out from under us. Abort rather than index into a
    // slot that no longer exists.
    if (dragging_) {
      [NSCursor pop];
      [self.window enableCursorRects];
      [[NSCursor arrowCursor] set];
    }
    draggingTab_ = nil;
    dragging_ = NO;
    joinTargetTab_.dropTarget = NO;
    joinTargetTab_ = nil;
    return;
  }
  CGFloat delta = (newX - groupOriginX) / slotWidth -
                  (CGFloat)(current - groupStart);
  NSInteger hoverIndex = current + (NSInteger)lround(delta);
  hoverIndex = MIN(MAX(hoverIndex, groupStart), groupEnd);
  BroTabView* joinTarget = nil;
  if (hoverIndex != current) {
    BOOL adjacent = labs(hoverIndex - current) == 1;
    CGFloat depth =
        fabs(delta) - (fabs((CGFloat)(hoverIndex - current)) - 0.5);
    if (adjacent && depth < 0.4) {
      joinTarget = _tabs[(NSUInteger)hoverIndex];
    } else {
      [_tabs removeObjectAtIndex:current];
      [_tabs insertObject:tab atIndex:hoverIndex];
      BroRunLayoutSpring(^{
        [self applyTabLayout:YES];
      }, nil);
    }
  }
  if (joinTargetTab_ != joinTarget) {
    joinTargetTab_.dropTarget = NO;
    joinTarget.dropTarget = YES;
    joinTargetTab_ = joinTarget;
  }
}

- (BOOL)endDragForTab:(BroTabView*)tab {
  if (tab != draggingTab_) {
    return NO;
  }
  BOOL didDrag = dragging_;
  draggingTab_ = nil;
  dragging_ = NO;
  BroTabView* joinTarget = joinTargetTab_;
  joinTargetTab_ = nil;
  joinTarget.dropTarget = NO;
  if (didDrag) {
    // Balances the push/disable from the first drag event.
    [NSCursor pop];
    [self.window enableCursorRects];
    [[NSCursor arrowCursor] set];
    // Snap the released pill into its slot, then drop it back to pill level.
    BroRunLayoutSpring(^{
      [self applyTabLayout:YES];
    }, ^{
      tab.layer.zPosition = 0.0;
    });
    [self.window recalculateKeyViewLoop];
    if (joinTarget) {
      // A deferred tab close (dispatch_async) can pull either pill out of
      // _tabs mid-drag, leaving joinTarget stale; skip the join instead of
      // handing a dead browser id to JoinTabsInSplit/SetActiveBrowser.
      if ([_tabs indexOfObject:tab] != NSNotFound &&
          [_tabs indexOfObject:joinTarget] != NSNotFound) {
        // Dropped onto another pill: split the two tabs.
        JoinTabsInSplit(tab.browserId, joinTarget.browserId);
      }
    } else if (SplitActive()) {
      // A drag can pull the split pair apart; snap it back together so the
      // joined pills keep mirroring the panes below.
      [self ensureSplitPairAdjacent];
    }
  }
  return didDrag;
}

- (void)focusTabRelativeTo:(BroTabView*)tab offset:(NSInteger)offset {
  NSInteger index = [_tabs indexOfObject:tab];
  if (index == NSNotFound) {
    return;
  }
  NSInteger next = index + offset;
  if (next < 0 || next >= (NSInteger)_tabs.count) {
    return;
  }
  [self scrollTabToVisible:_tabs[next]];
  [self.window makeFirstResponder:_tabs[next]];
}

- (void)activateTabRelativeToActiveWithOffset:(NSInteger)offset {
  NSInteger count = (NSInteger)_tabs.count;
  if (count < 2) {
    return;
  }
  NSInteger index = 0;
  for (NSInteger i = 0; i < count; i++) {
    if (_tabs[i].browserId == _activeTabId) {
      index = i;
      break;
    }
  }
  NSInteger next = ((index + offset) % count + count) % count;
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    handler->SetActiveBrowser(_tabs[next].browserId);
  }
}

- (void)togglePinForTab:(BroTabView*)tab {
  if (dragging_ || [_tabs indexOfObject:tab] == NSNotFound) {
    return;
  }
  BOOL pinning = !tab.pinned;
  [_tabs removeObject:tab];
  // After the removal, pinnedCount is both the end of the pinned group (where
  // a newly pinned pill lands) and the front of the unpinned group (where an
  // unpinned one returns).
  NSUInteger destination = [self pinnedCount];
  tab.pinned = pinning;
  [_tabs insertObject:tab atIndex:destination];
  if (SplitActive()) {
    // The pin move may have separated (or reunited) the joined split pair;
    // this restyles corners/seam and animates the same 0.18s layout.
    [self ensureSplitPairAdjacent];
    return;
  }
  BroRunLayoutSpring(^{
    [self applyTabLayout:YES];
  }, nil);
  [self.window recalculateKeyViewLoop];
}

- (void)removeTabWithBrowserId:(int)browserId {
  [self hideHoverCard];
  BroTabView* tabToRemove = nil;
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      tabToRemove = tab;
      break;
    }
  }

  if (tabToRemove) {
    if (tabToRemove == draggingTab_) {
      // The close is deferred (dispatch_async) so it can land mid-drag; tear
      // down the drag now, before the pill it was tracking disappears out
      // from under the next mouseDragged: event.
      if (dragging_) {
        [NSCursor pop];
        [self.window enableCursorRects];
        [[NSCursor arrowCursor] set];
      }
      draggingTab_ = nil;
      dragging_ = NO;
      joinTargetTab_.dropTarget = NO;
      joinTargetTab_ = nil;
    }
    // If the closed pill held keyboard focus, hand it to a neighbor so focus
    // doesn't silently fall back to the window.
    if (self.window.firstResponder == tabToRemove) {
      NSUInteger index = [_tabs indexOfObject:tabToRemove];
      BroTabView* neighbor = nil;
      if (index != NSNotFound && _tabs.count > 1) {
        neighbor = _tabs[index + 1 < _tabs.count ? index + 1 : index - 1];
      }
      [self.window makeFirstResponder:neighbor];
    }
    [_tabs removeObject:tabToRemove];

    // The closing pill collapses and fades while the survivors slide over to
    // fill the gap; it leaves the hierarchy once the animation finishes. Its
    // content stops autoresizing (a 0-width pill would invert the labels)
    // and gets clipped by the shrinking layer instead.
    tabToRemove.autoresizesSubviews = NO;
    tabToRemove.layer.masksToBounds = YES;
    NSRect collapsed = tabToRemove.frame;
    collapsed.size.width = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = 0.18;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      tabToRemove.animator.frame = collapsed;
      tabToRemove.animator.alphaValue = 0.0;
    } completionHandler:^{
      [tabToRemove removeFromSuperview];
    }];
    BroRunLayoutSpring(^{
      [self applyTabLayout:YES];
    }, nil);
    [self.window recalculateKeyViewLoop];
  }
}

- (void)setActiveTab:(int)browserId {
  [self hideHoverCard];
  _activeTabId = browserId;
  for (BroTabView* tab in _tabs) {
    tab.isActive = (tab.browserId == browserId);
  }

  if (g_toolbar) {
    // The viewport toggles reflect the active tab's own emulation state.
    [g_toolbar setViewportMode:TabIsMobile(browserId)];
  }

  // In a collapsed strip the newly active pill grows out of its square so its
  // URL can be read and typed, and the one it replaced shrinks back. The same
  // swap happens around a pinned pill in a roomy strip (compact inactive,
  // expanded active). Animate it; with no pins and room for everyone, every
  // pill is already the same width and there is nothing to move.
  if (([self isCollapsed] || [self pinnedCount] > 0) && !dragging_) {
    BroRunLayoutSpring(^{
      [self applyTabLayout:YES];
    }, nil);
  }
  [self revealActiveTab];
}

- (void)updateTabTitle:(int)browserId title:(NSString*)title {
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      // Pills display the host; the page title shows in the hover card.
      // CEF reports "about:blank" as the title of a blank page — never let
      // that reach the chrome.
      tab.pageTitle = BroURLIsBlank(title) ? kBroBlankTabTitle : title;
      break;
    }
  }
}

- (void)updateTabURL:(int)browserId url:(NSString*)url {
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      [tab setTabURL:url];
      break;
    }
  }
}

- (void)updateTabFavicon:(int)browserId faviconURL:(NSString*)url {
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      [tab setFaviconURL:url];
      break;
    }
  }
}

- (void)updateTabLoading:(int)browserId loading:(BOOL)loading {
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      [tab setLoading:loading];
      break;
    }
  }
}

- (CGFloat)availableStripWidth {
  // The right edge reserves the pinned "+" and Search Tabs controls. This is
  // the visible width of the pill document, not its potentially wider content.
  return MAX(0.0, NSWidth(self.bounds) - (kAddTabButtonSize + 8.0) -
                      (kButtonSize + 8.0));
}

// Pinned pills are kept as a strict prefix of _tabs; every layout and drag
// computation leans on that invariant.
- (NSUInteger)pinnedCount {
  NSUInteger count = 0;
  for (BroTabView* tab in _tabs) {
    if (!tab.pinned) {
      break;
    }
    count++;
  }
  return count;
}

// Compact pinned pills: all of them except an active one, which expands so
// the hosted address field stays usable.
- (NSUInteger)compactPinnedCount {
  NSUInteger count = 0;
  for (BroTabView* tab in _tabs) {
    if (!tab.pinned) {
      break;
    }
    if (!tab.isActive) {
      count++;
    }
  }
  return count;
}

// Strip width left for expandable pills once compact pinned tabs took theirs.
- (CGFloat)expandableStripWidth {
  return MAX(0.0, [self availableStripWidth] -
                      (CGFloat)[self compactPinnedCount] *
                          (kPinnedTabPillWidth + kTabGap));
}

// Fits expandable pills to the remaining strip width (minus the "+" button
// and compact pinned tabs), capped at the mockup's pill width. Only meaningful
// while the strip is roomy — once pills would go narrower than
// kTabPillTextMinWidth the layout switches to squares and this stops
// describing every pill (see -tabWidths).
- (CGFloat)fittedTabWidth {
  NSUInteger count =
      MAX(_tabs.count - [self compactPinnedCount], (NSUInteger)1);
  CGFloat fitWidth = [self expandableStripWidth] / count - kTabGap;
  return MIN(MAX(fitWidth, kTabPillSquareWidth), kTabPillMaxWidth);
}

// YES once equal pills would make the active URL narrower than its comfortable
// minimum. In that state inactive pills become compact and the document may
// scroll so the active pill never has to collapse.
- (BOOL)isCollapsed {
  NSUInteger count =
      MAX(_tabs.count - [self compactPinnedCount], (NSUInteger)1);
  return [self expandableStripWidth] / count - kTabGap < kTabPillMinWidth;
}

// Width of one drag slot for `tab`. Pinned pills only travel their compact
// group; collapsed unpinned pills travel square-sized slots.
- (CGFloat)dragSlotWidthForTab:(BroTabView*)tab {
  return (tab.pinned ? kPinnedTabPillWidth
                     : ([self isCollapsed] ? kTabPillSquareWidth
                                           : [self fittedTabWidth])) +
         kTabGap;
}

// Per-pill widths in strip order. Pinned inactive pills stay compact;
// the rest are uniform while there is room. Collapsed, every inactive pill is
// a square and the active one takes the leftover space so its URL stays
// readable and editable.
- (NSArray<NSNumber*>*)tabWidths {
  NSMutableArray<NSNumber*>* widths =
      [NSMutableArray arrayWithCapacity:_tabs.count];
  if (![self isCollapsed]) {
    CGFloat uniform = [self fittedTabWidth];
    for (BroTabView* tab in _tabs) {
      [widths addObject:@(tab.pinned && !tab.isActive ? kPinnedTabPillWidth
                                                      : uniform)];
    }
    return widths;
  }
  CGFloat fixedInactiveWidth = 0.0;
  BroTabView* activeTab = nil;
  for (BroTabView* tab in _tabs) {
    if (tab.isActive) {
      activeTab = tab;
    } else {
      fixedInactiveWidth +=
          (tab.pinned ? kPinnedTabPillWidth : kTabPillSquareWidth) + kTabGap;
    }
  }
  CGFloat slack = [self availableStripWidth] - fixedInactiveWidth - kTabGap;
  // When slack runs out, overflow belongs to the scroll document—not to the
  // active address pill. Keep it readable even with dozens of tabs.
  CGFloat activeWidth =
      MIN(kTabPillMaxWidth, MAX(kTabPillMinWidth, slack));
  for (BroTabView* tab in _tabs) {
    CGFloat compactWidth =
        tab.pinned ? kPinnedTabPillWidth : kTabPillSquareWidth;
    [widths addObject:@(tab.isActive ? activeWidth : compactWidth)];
  }
  return widths;
}

// Keeps the current scroll offset inside the document after tabs close or the
// window widens enough that overflow disappears.
- (void)clampScrollOffset {
  NSClipView* clip = tabScrollView_.contentView;
  NSPoint origin = clip.bounds.origin;
  CGFloat maxX = MAX(0.0, NSWidth(tabContentView_.frame) -
                              NSWidth(clip.bounds));
  origin.x = MIN(MAX(0.0, origin.x), maxX);
  origin.y = 0.0;
  [clip scrollToPoint:origin];
  [tabScrollView_ reflectScrolledClipView:clip];
}

// Reveals only when needed, preserving the user's position when the complete
// pill is already visible.
- (void)scrollTabToVisible:(BroTabView*)tab {
  if (!tab || ![_tabs containsObject:tab] || dragging_) {
    return;
  }
  NSClipView* clip = tabScrollView_.contentView;
  NSRect visible = clip.bounds;
  NSRect target = NSInsetRect(tab.frame, -4.0, 0.0);
  if (NSContainsRect(visible, target)) {
    return;
  }
  CGFloat x = NSMinX(visible);
  if (NSMinX(target) < NSMinX(visible)) {
    x = NSMinX(target);
  } else if (NSMaxX(target) > NSMaxX(visible)) {
    x = NSMaxX(target) - NSWidth(visible);
  }
  CGFloat maxX = MAX(0.0, NSWidth(tabContentView_.frame) - NSWidth(visible));
  NSPoint origin = NSMakePoint(MIN(MAX(0.0, x), maxX), 0.0);
  [clip scrollToPoint:origin];
  [tabScrollView_ reflectScrolledClipView:clip];
}

- (void)revealActiveTab {
  [self scrollTabToVisible:[self tabWithBrowserId:_activeTabId]];
}

// Positions pills and sizes their scroll document. Pill frames and the
// trailing "+" always move through the animator proxy: inside an animated
// caller's group they spring to their slots, and inside applyTabLayout:'s
// zero-duration group they land immediately AND cancel any spring still in
// flight. The search button never participates.
- (void)layOutTabsThroughAnimator {
  CGFloat height = NSHeight(self.bounds);
  CGFloat viewportWidth = [self availableStripWidth];
  tabScrollView_.frame = NSMakeRect(0, 0, viewportWidth, height);

  CGFloat pillY = (height - kTabPillHeight) / 2.0;
  NSArray<NSNumber*>* widths = [self tabWidths];

  CGFloat x = 0.0;
  NSUInteger index = 0;
  for (BroTabView* tab in _tabs) {
    CGFloat tabWidth = widths[index++].doubleValue;
    // Narrow pills drop the close button so it doesn't crowd the favicon and
    // title; narrower still they keep only the favicon. Pinned pills never
    // show ✕ (Cmd+W still closes them).
    tab.closable =
        !tab.pinned && _tabs.count > 1 && tabWidth >= kTabPillCloseMinWidth;
    tab.iconOnly = tabWidth < kTabPillTextMinWidth;
    NSRect target = NSMakeRect(x, pillY, tabWidth, kTabPillHeight);
    if (dragging_ && tab == draggingTab_) {
      // The dragged pill follows the mouse; its slot stays reserved.
    } else {
      tab.animator.frame = target;
    }
    // The split pair overlaps by 1pt so the two borders coincide and the
    // pair reads as one continuous pill; every other neighbor keeps the
    // normal gap.
    x += tabWidth - (tab.joinedSide == 1 ? kSplitJoinedOverlap : -kTabGap);
  }

  CGFloat documentWidth = MAX(viewportWidth, x);
  tabContentView_.frame = NSMakeRect(0, 0, documentWidth, height);
  [self clampScrollOffset];

  // The "+" trails the last pill by one gap (`x` already carries it) so it
  // reads as part of the strip. Once the pills overflow it stops advancing and
  // parks at the viewport's clipped edge, where it stays put while scrolling.
  NSRect addTarget =
      NSMakeRect(MIN(x, viewportWidth), (height - kAddTabButtonSize) / 2.0,
                 kAddTabButtonSize, kAddTabButtonSize);
  _addTabButton.animator.frame = addTarget;

  // The search button never trails the pills; it stays pinned at the right
  // edge.
  _tabSearchButton.frame =
      NSMakeRect(NSWidth(self.bounds) - kButtonSize,
                 (height - kButtonSize) / 2.0,
                 kButtonSize, kButtonSize);

  [self revealActiveTab];
}

// An unanimated layout must WIN over any spring still animating a pill --
// otherwise the spring keeps ticking and lands that pill back on the target
// it was given for the old strip width, overlapping its neighbors. (Seen when
// activating a desktop tab from the mobile shell: the activation spring and
// the window's resize-driven relayout ran together, and only the pills whose
// slot happened not to move came out right.) Assigning through the animator
// inside a zero-duration group both sets the frame now and cancels the
// in-flight animation; a plain `frame` set does not.
- (void)applyTabLayout:(BOOL)animated {
  if (animated) {
    [self layOutTabsThroughAnimator];
    return;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
    context.duration = 0.0;
    [self layOutTabsThroughAnimator];
  }];
}

- (void)layoutTabs {
  [self applyTabLayout:NO];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  [self layoutTabs];
  // A resize invalidates the card's position; hiding beats tracking it.
  [self hideHoverCard];
  // Same for the command palette, whose centering is now stale.
  HideCommandPalette();
}

- (void)tabSelected:(BroTabView*)tab {
  if (tab.browserId == _activeTabId) {
    // Already active; the pill hosts no URL editor, so there is nothing
    // further a click should do (drag-to-reorder is handled separately).
    return;
  }
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    handler->SetActiveBrowser(tab.browserId);
  }
}

- (void)tabClosed:(BroTabView*)tab {
  if (_tabs.count <= 1) {
    // Closing the last tab closes the window (and quits, like a browser).
    [self.window performClose:nil];
    return;
  }

  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    handler->CloseBrowser(tab.browserId);
  }
}

#pragma mark Hover card

- (void)tabHoverBegan:(BroTabView*)tab {
  if (dragging_) {
    return;
  }
  [hoverCardHideTimer_ invalidate];
  hoverCardHideTimer_ = nil;
  [hoverCardTimer_ invalidate];
  hoverCardTimer_ = nil;
  // Once a card is up, moving across pills retargets it without a new dwell
  // (like every browser's tab strip).
  // hoverCardTabId_ is cleared as soon as hiding begins. AppKit leaves the
  // view unhidden for the 120ms fade, so hidden alone would mistake a
  // dismissing card for a presented one and retarget it immediately.
  if (hoverCard_ && hoverCardTabId_ >= 0 && !hoverCard_.hidden) {
    if ([self hoverCardHasKeyboardFocus]) {
      return;
    }
    [self showHoverCardForTab:tab];
    return;
  }
  __weak BroTabView* weakTab = tab;
  __weak BroTabBar* weakSelf = self;
  hoverCardTimer_ =
      [NSTimer scheduledTimerWithTimeInterval:kHoverCardDelay
                                      repeats:NO
                                        block:^(NSTimer* timer) {
        BroTabBar* bar = weakSelf;
        BroTabView* hoveredTab = weakTab;
        if (!bar || timer != bar->hoverCardTimer_ || !hoveredTab ||
            ![bar.tabs containsObject:hoveredTab]) {
          return;
        }
        bar->hoverCardTimer_ = nil;
        [bar showHoverCardForTab:hoveredTab];
      }];
}

- (void)tabHoverEnded:(BroTabView*)tab {
  // A dwell that hasn't fired is simply abandoned; a visible card gets the
  // grace period so the mouse can travel onto it.
  [hoverCardTimer_ invalidate];
  hoverCardTimer_ = nil;
  [self scheduleHoverCardHide];
}

- (void)cardHoverBegan {
  [hoverCardHideTimer_ invalidate];
  hoverCardHideTimer_ = nil;
}

- (void)cardHoverEnded {
  [self scheduleHoverCardHide];
}

- (BOOL)hoverCardHasKeyboardFocus {
  NSResponder* responder = self.window.firstResponder;
  if (![responder isKindOfClass:[NSView class]] || !hoverCard_) {
    return NO;
  }
  NSView* view = (NSView*)responder;
  return view == hoverCard_ || [view isDescendantOf:hoverCard_];
}

- (void)unwireHoverCardKeyLoop {
  if (hoverCardKeyAnchor_.nextKeyView == hoverCard_.pinButton) {
    hoverCardKeyAnchor_.nextKeyView = hoverCardReturnKeyView_;
  }
  hoverCardKeyAnchor_ = nil;
  hoverCardReturnKeyView_ = nil;
  hoverCardSourceTab_ = nil;
}

- (void)wireHoverCardKeyLoopForTab:(BroTabView*)tab {
  [self unwireHoverCardKeyLoop];
  if (!tab || !hoverCard_ || hoverCard_.hidden || !self.window) {
    return;
  }
  [self.window recalculateKeyViewLoop];
  NSView* anchor = tab;
  if (!tab.closeButton.hidden && tab.nextKeyView == tab.closeButton) {
    anchor = tab.closeButton;
  }
  hoverCardKeyAnchor_ = anchor;
  hoverCardReturnKeyView_ = anchor.nextKeyView;
  hoverCardSourceTab_ = tab;
  anchor.nextKeyView = hoverCard_.pinButton;
  hoverCard_.pinButton.nextKeyView = hoverCard_.splitButton;
  hoverCard_.splitButton.nextKeyView = hoverCardReturnKeyView_;
}

- (void)tabFocusBegan:(BroTabView*)tab {
  if (hidingHoverCard_) {
    return;
  }
  [self scrollTabToVisible:tab];
  [hoverCardTimer_ invalidate];
  hoverCardTimer_ = nil;
  [hoverCardHideTimer_ invalidate];
  hoverCardHideTimer_ = nil;
  [self showHoverCardForTab:tab];
  [self wireHoverCardKeyLoopForTab:tab];
}

- (void)tabFocusEnded:(BroTabView*)tab {
  if (hoverCardSourceTab_ == tab) {
    [self scheduleHoverCardHide];
  }
}

- (void)scheduleHoverCardHide {
  [hoverCardHideTimer_ invalidate];
  hoverCardHideTimer_ = nil;
  if (!hoverCard_ || hoverCard_.hidden) {
    return;
  }
  __weak BroTabBar* weakSelf = self;
  hoverCardHideTimer_ =
      [NSTimer scheduledTimerWithTimeInterval:kHoverCardHideGrace
                                      repeats:NO
                                        block:^(NSTimer* timer) {
        BroTabBar* bar = weakSelf;
        if (bar && ![bar hoverCardHasKeyboardFocus]) {
          [bar hideHoverCard];
        }
      }];
}

- (void)hideHoverCard {
  [hoverCardTimer_ invalidate];
  hoverCardTimer_ = nil;
  [hoverCardHideTimer_ invalidate];
  hoverCardHideTimer_ = nil;
  BOOL cardHadFocus = [self hoverCardHasKeyboardFocus];
  BroTabView* sourceTab = hoverCardSourceTab_;
  hidingHoverCard_ = YES;
  [self unwireHoverCardKeyLoop];
  BroOverlayHide(hoverCard_);
  hoverCardTabId_ = -1;
  [self.window recalculateKeyViewLoop];
  if (cardHadFocus && sourceTab && [_tabs containsObject:sourceTab]) {
    [self.window makeFirstResponder:sourceTab];
  }
  hidingHoverCard_ = NO;
}

// Title shown on the card; falls back to the display host for pages that
// never reported one.
- (NSString*)hoverCardTitleForTab:(BroTabView*)tab {
  return tab.pageTitle.length > 0 ? tab.pageTitle
                                  : BroDisplayHostForURL(tab.tabURL);
}

- (BroTabView*)tabWithBrowserId:(int)browserId {
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      return tab;
    }
  }
  return nil;
}

- (void)configureHoverCardButtonsForTab:(BroTabView*)tab {
  BroHoverButton* pin = hoverCard_.pinButton;
  pin.image = RadixIconImage(
      tab.pinned ? RadixIconDrawingPinFilled : RadixIconDrawingPin, 12);
  [pin configureActionLabel:(tab.pinned ? @"Unpin Tab" : @"Pin Tab")
              keyEquivalent:@"p"
               modifierMask:NSEventModifierFlagCommand |
                            NSEventModifierFlagOption];
  pin.target = self;
  pin.action = @selector(hoverCardPinPressed:);

  BroHoverButton* split = hoverCard_.splitButton;
  split.image = RadixIconImage(RadixIconViewVertical, 12);
  BOOL isPane = SplitActive() && (tab.browserId == g_split_browser_id ||
                                  tab.browserId == _activeTabId);
  split.selectedState = isPane;
  // A non-active tab becomes the right pane; the active tab pairs with its
  // next neighbor; either pane's button exits the split. Only a lone tab has
  // nothing to split with.
  split.enabled = isPane || _tabs.count > 1;
  [split configureActionLabel:(isPane ? @"Exit Split Screen" : @"Split Screen")
                keyEquivalent:@"s"
                 modifierMask:NSEventModifierFlagCommand |
                              NSEventModifierFlagShift];
  split.target = self;
  split.action = @selector(hoverCardSplitPressed:);
}

- (void)hoverCardPinPressed:(id)sender {
  BroTabView* tab = [self tabWithBrowserId:hoverCardTabId_];
  [self hideHoverCard];
  if (tab) {
    [self togglePinForTab:tab];
  }
}

- (void)hoverCardSplitPressed:(id)sender {
  int browserId = hoverCardTabId_;
  [self hideHoverCard];
  if (browserId < 0) {
    return;
  }
  // On the active tab's own card there is no "other" tab in hand; pair it
  // with its neighbor, same as the Window menu item.
  if (browserId == _activeTabId && !SplitActive()) {
    [self splitActiveTabWithNextTab];
    return;
  }
  ToggleSplitForTab(browserId);
}

- (BOOL)performContextualPinShortcut {
  if (!hoverCard_ || hoverCard_.hidden || hoverCardTabId_ < 0) {
    return NO;
  }
  [hoverCard_.pinButton performClick:nil];
  return YES;
}

- (BOOL)performContextualSplitShortcut {
  if (!hoverCard_ || hoverCard_.hidden || hoverCardTabId_ < 0) {
    return NO;
  }
  [hoverCard_.splitButton performClick:nil];
  return YES;
}

- (void)splitActiveTabWithNextTab {
  NSInteger count = (NSInteger)_tabs.count;
  if (count < 2) {
    return;
  }
  NSInteger index = 0;
  for (NSInteger i = 0; i < count; i++) {
    if (_tabs[i].browserId == _activeTabId) {
      index = i;
      break;
    }
  }
  ToggleSplitForTab(_tabs[(index + 1) % count].browserId);
}

- (void)ensureSplitPairAdjacent {
  if (!dragging_ && SplitActive()) {
    BroHandler* handler = BroHandler::GetInstance();
    int activeId = handler ? handler->GetActiveBrowserId() : -1;
    NSUInteger activeIndex = BroTabStripIndex(activeId);
    NSUInteger splitIndex = BroTabStripIndex(g_split_browser_id);
    if (activeIndex != NSNotFound && splitIndex != NSNotFound) {
      BroTabView* activeTab = _tabs[activeIndex];
      BroTabView* splitTab = _tabs[splitIndex];
      NSUInteger gap = activeIndex > splitIndex ? activeIndex - splitIndex
                                                : splitIndex - activeIndex;
      // Never carry a pill across the pinned prefix; a cross-group pair just
      // stays where it is (no joined rendering, still a working split).
      if (gap != 1 && activeTab.pinned == splitTab.pinned) {
        [_tabs removeObjectAtIndex:splitIndex];
        NSUInteger target = [_tabs indexOfObject:activeTab];
        if (splitIndex > activeIndex) {
          target += 1;  // was after the active pill; stays on its right
        }
        [_tabs insertObject:splitTab atIndex:target];
      }
    }
  }
  // Styling first: the joined-pair seam feeds the gap applyTabLayout uses
  // (and on split exit this restores the normal gap and corners).
  RefreshSplitPaneStyling();
  BroRunLayoutSpring(^{
    [self applyTabLayout:YES];
  }, nil);
  [self.window recalculateKeyViewLoop];
}

- (void)showHoverCardForTab:(BroTabView*)tab {
  NSView* container = BroBrowserContainerView();
  if (dragging_ || !container) {
    return;
  }
  if (!hoverCard_) {
    hoverCard_ = [[BroTabHoverCard alloc] initWithFrame:NSZeroRect];
    hoverCard_.hidden = YES;
  }
  BOOL wasVisible = !hoverCard_.hidden;
  // Re-add last on every show: tab containers created since the previous
  // hover stack above the card, and the native CEF views inside them would
  // occlude it.
  [hoverCard_ removeFromSuperview];
  [container addSubview:hoverCard_];
  hoverCard_.hoverDelegate = self;

  // The card matches the hovered pill's width, reading as a dropdown of the
  // pill; collapsed squares get the pill minimum so the text stays legible.
  CGFloat width = MIN(MAX(NSWidth(tab.frame), kTabPillMinWidth),
                      NSWidth(container.bounds) - 16.0);
  if (width < 100.0) {
    return;  // window too narrow for a useful card
  }
  hoverCardTabId_ = tab.browserId;
  [self configureHoverCardButtonsForTab:tab];
  if (BroURLIsBlank(tab.tabURL)) {
    // Blank tabs have no URL or metadata worth showing; the card invites
    // instead (mirrors the address field's empty state).
    [hoverCard_ setTitle:kBroBlankTabTitle
                     url:@"Ask anything…"
         pageDescription:nil
                   width:width];
  } else {
    [hoverCard_ setTitle:[self hoverCardTitleForTab:tab]
                     url:BroDisplayHostForURL(tab.tabURL)
         pageDescription:tab.pageDescription
                   width:width];
  }
  [self positionHoverCardForTab:tab animated:wasVisible];
  BroOverlayShow(hoverCard_);

  // Fetch the description on first hover per page; the card shows right away
  // with title + URL and fills in when (if) the result arrives.
  if (tab.pageDescription == nil && !BroURLIsBlank(tab.tabURL)) {
    BroHandler* handler = BroHandler::GetInstance();
    if (handler) {
      handler->FetchTabDescription(tab.browserId);
    }
  }
}

// Hangs the card just below the toolbar, x-aligned with the pill and clamped
// to the container edges.
- (void)positionHoverCardForTab:(BroTabView*)tab animated:(BOOL)animated {
  NSView* container = hoverCard_.superview;
  if (!container || ![_tabs containsObject:tab]) {
    return;
  }
  NSRect pill = [container convertRect:tab.bounds fromView:tab];
  NSSize size = hoverCard_.frame.size;
  CGFloat x = MIN(NSMinX(pill), NSMaxX(container.bounds) - size.width - 8.0);
  x = MAX(x, 8.0);
  CGFloat y = NSMaxY(container.bounds) - size.height - 6.0;
  NSRect target = NSMakeRect(x, y, size.width, size.height);
  if (animated) {
    BroSpringRetargetFrame(hoverCard_, target, BroSpringLayout,
                           @"bro.hover-card.frame");
  } else {
    hoverCard_.frame = target;
  }
}

- (void)updateTabDescription:(int)browserId description:(NSString*)desc {
  for (BroTabView* tab in _tabs) {
    if (tab.browserId != browserId) {
      continue;
    }
    // Empty string caches "fetched, page has none" (vs nil = never fetched).
    tab.pageDescription = desc ?: @"";
    // Live-fill the visible card. A tab that went blank since the fetch keeps
    // its "New Tab" card instead of a stale page's data.
    if (hoverCardTabId_ == browserId && hoverCard_ && !hoverCard_.hidden &&
        !BroURLIsBlank(tab.tabURL)) {
      [hoverCard_ setTitle:[self hoverCardTitleForTab:tab]
                       url:BroDisplayHostForURL(tab.tabURL)
           pageDescription:tab.pageDescription
                     width:hoverCard_.frame.size.width];
      [self positionHoverCardForTab:tab animated:YES];
    }
    break;
  }
}

@end
