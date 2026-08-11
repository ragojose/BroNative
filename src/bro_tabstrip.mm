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

#pragma mark - BroHoverButton

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
    self.layer.cornerRadius = kControlCornerRadius;
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
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    focused_ = YES;
    [self refreshBorder];
  }
  return ok;
}

- (BOOL)resignFirstResponder {
  BOOL ok = [super resignFirstResponder];
  if (ok) {
    focused_ = NO;
    [self refreshBorder];
  }
  return ok;
}

// Hover/pressed feedback needs an enabled button, but the selected
// background persists even when the toggle is disabled (a selected viewport
// mode is inert until the other one is chosen).
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
      alpha > 0 ? [NSColor colorWithWhite:1.0 alpha:alpha].CGColor
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
  hovered_ = NO;
  pressed_ = NO;
  [_highlightGroup hoverOffView:self];
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
  [self refreshBackground];
  [self refreshTransform];
}

- (void)mouseExited:(NSEvent*)event {
  hovered_ = NO;
  pressed_ = NO;
  [_highlightGroup hoverOffView:self];
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
  // Space is handled by NSButton; add Return as an activator too.
  NSString* chars = event.charactersIgnoringModifiers;
  unichar c = chars.length > 0 ? [chars characterAtIndex:0] : 0;
  if (c == '\r' || c == NSEnterCharacter) {
    [self performClick:self];
    return;
  }
  [super keyDown:event];
}

@end

#pragma mark - BroTabView

// BroTabView's and BroAddressField's @interfaces are declared in
// bro_mac_internal.h (shared with the toolbar). BroTabBar's @interface is
// declared there too (shared with bro_tabsearch.mm).

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
  BOOL hovered_;
  BOOL focused_;
  BOOL wasActiveAtMouseDown_;
  // Target state of the ✕ fade; guards against the many updateAppearance
  // callers restarting an in-flight fade.
  BOOL closeButtonShown_;
  // Bumped on every setFaviconURL:; a fetch completion only applies its image
  // if the generation still matches, so a slow response for a previous page
  // can't overwrite the current page's favicon. Main-thread only.
  NSUInteger faviconGeneration_;
}

- (instancetype)initWithFrame:(NSRect)frame browserId:(int)browserId {
  self = [super initWithFrame:frame];
  if (self) {
    _browserId = browserId;
    _isActive = NO;
    _isLoading = NO;
    _tabURL = @"";

    self.wantsLayer = YES;
    self.layer.cornerRadius = kPillCornerRadius;
    self.layer.borderWidth = 1.0;
    self.layer.actions = BroLayerTransitionActions();
    // Keyboard focus shows as a white pill border instead of the system's
    // accent-colored ring.
    self.focusRingType = NSFocusRingTypeNone;

    // Favicon view
    _faviconView = [[NSImageView alloc]
        initWithFrame:NSMakeRect(10, (kTabPillHeight - 15) / 2.0, 15, 15)];
    _faviconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    // Default globe icon
    _faviconView.image = RadixIconImage(RadixIconGlobe, 15);
    _faviconView.contentTintColor = [NSColor colorWithWhite:0x33 / 255.0 alpha:1.0];
    [self addSubview:_faviconView];

    // Loading spinner (same position as favicon, hidden by default)
    _loadingSpinner = [[NSProgressIndicator alloc] initWithFrame:_faviconView.frame];
    _loadingSpinner.style = NSProgressIndicatorStyleSpinning;
    _loadingSpinner.controlSize = NSControlSizeSmall;
    _loadingSpinner.hidden = YES;
    [self addSubview:_loadingSpinner];

    // Host label (hidden on the active pill, where the address field shows)
    _titleLabel = [[BroTextMorphView alloc]
        initWithFont:BroUIFont(kTabTextFontSize)
                 color:[NSColor secondaryLabelColor]];
    _titleLabel.frame = NSMakeRect(
        32, (kTabPillHeight - kTabTextFrameHeight) / 2.0,
        frame.size.width - 32 - 26, kTabTextFrameHeight);
    [_titleLabel setText:kBroBlankTabTitle animated:NO];
    _titleLabel.autoresizingMask = NSViewWidthSizable;
    [self addSubview:_titleLabel];

    // Close button (visible whenever the pill is closable; the tab bar hides
    // it on a lone tab)
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
    closeButton.layer.cornerRadius =
        BroNestedCornerRadius(kPillCornerRadius, closeButtonGap);
    closeButton.target = self;
    closeButton.action = @selector(handleClose:);
    closeButton.autoresizingMask = NSViewMinXMargin;
    closeButton.accessibilityLabel = @"Close tab";
    closeButton.toolTip = @"Close tab (⌘W)";
    _closeButton = closeButton;
    // Start hidden to match closeButtonShown_'s NO default, so the guard in
    // setCloseButtonShown: can't leave a stale ✕ on a non-closable pill.
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
  [_titleLabel setText:display animated:self.window != nil];
}

// Hosts the toolbar's shared address field (this pill is the active tab).
// layoutPillContents owns the geometry — attaching to a collapsed square and
// letting autoresizing stretch the field from a negative width drifted it off
// the text inset and put it on top of the favicon.
- (void)attachAddressField:(NSTextField*)field {
  field.autoresizingMask = NSViewNotSizable;
  [self addSubview:field];
  _editingAddress = NO;
  [self layoutPillContents];
}

// Single place deciding what the pill shows at its current width: normally the
// favicon sits at the left inset with text beside it; collapsed, the favicon
// centers and both the host label and the hosted address field step aside.
- (void)layoutPillContents {
  CGFloat iconX = _iconOnly ? (self.bounds.size.width - 15) / 2.0 : 10.0;
  NSRect iconFrame = NSMakeRect(iconX, (kTabPillHeight - 15) / 2.0, 15, 15);
  _faviconView.frame = iconFrame;
  _loadingSpinner.frame = iconFrame;
  // Resting active and inactive tabs deliberately share the morph view. The
  // NSTextField appears only while editing, eliminating the renderer/baseline
  // swap that made text jump when merely changing tabs.
  BOOL showEditor = _isActive && _editingAddress;
  _titleLabel.hidden = _iconOnly || showEditor;

  // Text runs from the favicon's right edge to just inside the ✕ (or the
  // pill's edge when there is no room for one). Clamped at zero so a collapsed
  // pill can't produce a negative width.
  CGFloat textRight = _closable ? 26.0 : 10.0;
  NSRect textFrame =
      NSMakeRect(32,
                 (self.bounds.size.height - kTabTextFrameHeight) / 2.0,
                 MAX(0.0, self.bounds.size.width - 32 - textRight),
                 kTabTextFrameHeight);
  _titleLabel.frame = textFrame;
  for (NSView* v in self.subviews) {
    if ([v isKindOfClass:[BroAddressField class]]) {
      v.hidden = _iconOnly || !showEditor;
      v.frame = textFrame;
      break;
    }
  }
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
    return;  // Repeated OnLoadingStateChange must not restart the spinner.
  }
  _isLoading = loading;
  if (loading) {
    _faviconView.hidden = YES;
    _loadingSpinner.hidden = NO;
    [_loadingSpinner startAnimation:nil];
  } else {
    [_loadingSpinner stopAnimation:nil];
    _loadingSpinner.hidden = YES;
    _faviconView.hidden = NO;
  }
}

// Pills sit on pure #000; selection, split-pane, hover, keyboard focus, and
// the address-editing state all share the same 1pt #111 hairline, and only a
// hovered inactive pill lifts its fill off black. Resting inactive borders
// are fainter still.
- (void)updateAppearance {
  if (_isActive) {
    self.layer.backgroundColor = [NSColor blackColor].CGColor;
    self.layer.borderColor = BroControlBorderColor().CGColor;
    _titleLabel.color = [NSColor labelColor];
  } else {
    // The split screen's right pane keeps the active pill's look while
    // inactive, so both on-screen halves read as selected — with a faint
    // lift so the two halves of the joined pill are still tellable apart.
    CGFloat bg = (!_isSplitPane && hovered_) ? 0.05 : (_isSplitPane ? 0.03 : 0.0);
    self.layer.backgroundColor =
        bg > 0 ? [NSColor colorWithWhite:1.0 alpha:bg].CGColor
               : [NSColor blackColor].CGColor;
    self.layer.borderColor =
        (_isSplitPane || hovered_ || focused_)
            ? BroControlBorderColor().CGColor
            : [NSColor colorWithWhite:1.0 alpha:0.05].CGColor;
    _titleLabel.color = [NSColor secondaryLabelColor];
  }
  // A dragged pill hovering this one (drop = split the two tabs) outshines
  // every other state so the target is unmistakable.
  if (_dropTarget) {
    self.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.14].CGColor;
    self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.6].CGColor;
  }
  // The active pill always shows ✕; inactive pills reveal it on hover or
  // keyboard focus.
  [self setCloseButtonShown:(_closable && (_isActive || hovered_ || focused_))];
}

// Fades the ✕ in/out instead of snapping, so its hover reveal matches the
// rest of the chrome's transitions.
- (void)setCloseButtonShown:(BOOL)shown {
  if (shown == closeButtonShown_) {
    return;
  }
  closeButtonShown_ = shown;
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
    _closeButton.hidden = NO;
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
      if (strongSelf && !strongSelf->closeButtonShown_) {
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

- (void)setIsActive:(BOOL)isActive {
  _isActive = isActive;
  if (!isActive) {
    _editingAddress = NO;
  }
  [self updateAppearance];
  [self layoutPillContents];
}

- (void)setEditingAddress:(BOOL)editingAddress {
  _editingAddress = editingAddress;
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

// The pill owns its whole surface, so it can be picked up anywhere — the same
// click-through BroAddressField gives the active pill while idle. Without
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
  // While the address field is being edited it owns the mouse, so text
  // selection still works. Idle, it already hit-tests to nil, so this only
  // matches mid-edit; the field editor is a descendant, hence the walk.
  for (NSView* v = hit; v && v != self; v = v.superview) {
    if ([v isKindOfClass:[BroAddressField class]]) {
      return hit;
    }
  }
  return self;
}

// Switching tabs happens on mouse-down (like real browsers). Focusing the
// active pill's address field waits until mouse-up so starting a drag on the
// active tab doesn't drop into URL editing. Any pill can be picked up and
// dragged to reorder the strip.
- (void)mouseDown:(NSEvent*)event {
  wasActiveAtMouseDown_ = _isActive;
  if (!_isActive) {
    [self performSelect];
  }
  if ([self.superview isKindOfClass:[BroTabBar class]]) {
    [(BroTabBar*)self.superview beginPotentialDragForTab:self withEvent:event];
  }
}

- (void)mouseDragged:(NSEvent*)event {
  if ([self.superview isKindOfClass:[BroTabBar class]]) {
    [(BroTabBar*)self.superview dragTab:self withEvent:event];
  }
}

- (void)mouseUp:(NSEvent*)event {
  BOOL dragged = NO;
  if ([self.superview isKindOfClass:[BroTabBar class]]) {
    dragged = [(BroTabBar*)self.superview endDragForTab:self];
  }
  if (!dragged && wasActiveAtMouseDown_) {
    [self performSelect];
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
  if ([self.superview isKindOfClass:[BroTabBar class]]) {
    [(BroTabBar*)self.superview tabHoverBegan:self];
  }
}

- (void)mouseExited:(NSEvent*)event {
  hovered_ = NO;
  [self updateAppearance];
  if ([self.superview isKindOfClass:[BroTabBar class]]) {
    [(BroTabBar*)self.superview tabHoverEnded:self];
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
  }
  return ok;
}

- (BOOL)resignFirstResponder {
  BOOL ok = [super resignFirstResponder];
  if (ok) {
    focused_ = NO;
    [self updateAppearance];
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
    if ([self.superview isKindOfClass:[BroTabBar class]]) {
      [(BroTabBar*)self.superview
          focusTabRelativeTo:self
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
  BroTextMorphView* titleLabel_;
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
  label.textColor = [NSColor colorWithWhite:1.0 alpha:whiteAlpha];
  label.lineBreakMode = NSLineBreakByTruncatingTail;
  label.cell.truncatesLastVisibleLine = YES;
  return label;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.cornerRadius = kSurfaceCornerRadius;
    BroApplyElevation(self, BroElevationOverlay);

    titleLabel_ = [[BroTextMorphView alloc]
        initWithFont:BroUIFontBold(12.0) color:[NSColor whiteColor]];
    urlLabel_ = BroHoverCardLabel(BroUIFont(11.0), 0.55);
    descriptionLabel_ = BroHoverCardLabel(BroUIFont(11.0), 0.75);
    descriptionLabel_.lineBreakMode = NSLineBreakByWordWrapping;
    descriptionLabel_.cell.wraps = YES;
    [self addSubview:titleLabel_];
    [self addSubview:urlLabel_];
    [self addSubview:descriptionLabel_];

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
  button.contentTintColor = [NSColor colorWithWhite:1.0 alpha:0.85];
  [self addSubview:button];
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

  [titleLabel_ setText:title ?: @""
               animated:self.window != nil && !self.hidden];
  urlLabel_.stringValue = url ?: @"";
  descriptionLabel_.stringValue = desc ?: @"";
  descriptionLabel_.hidden = desc.length == 0;

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

@implementation BroTabBar {
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
    // Pills that still don't fit at their hard minimum width are clipped
    // rather than drawn over the controls to the right of the strip.
    self.layer.masksToBounds = YES;

    // Bordered rounded-rect "+" button, repositioned after the last pill.
    CGFloat addY = (frame.size.height - kAddTabButtonSize) / 2.0;
    _addTabButton = [[BroHoverButton alloc]
        initWithFrame:NSMakeRect(0, addY, kAddTabButtonSize, kAddTabButtonSize)];
    _addTabButton.bordered = NO;
    _addTabButton.title = @"";
    _addTabButton.image = RadixIconImage(RadixIconPlus, 10);
    _addTabButton.imagePosition = NSImageOnly;
    _addTabButton.contentTintColor = [NSColor colorWithWhite:1.0 alpha:0.85];
    _addTabButton.layer.cornerRadius = kCompactControlCornerRadius;
    _addTabButton.baseBorderWidth = 1.0;
    _addTabButton.baseBorderColor = BroControlBorderColor();
    _addTabButton.target = self;
    _addTabButton.action = @selector(createNewTab:);
    _addTabButton.accessibilityLabel = @"New tab";
    _addTabButton.toolTip = @"New tab (⌘N)";
    [self addSubview:_addTabButton];

    // Palette search button, pinned at the strip's right edge (the "+"
    // button trails the last pill; this one never moves). Sized and styled
    // like the toolbar buttons to its right — it reads as part of that
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
    _tabSearchButton.contentTintColor = [NSColor colorWithWhite:1.0 alpha:0.85];
    _tabSearchButton.target = self;
    _tabSearchButton.action = @selector(toggleTabSearch:);
    _tabSearchButton.accessibilityLabel = @"Search tabs";
    _tabSearchButton.toolTip = @"Search tabs (⇧⌘A)";
    _tabSearchButton.alphaValue = 0.0;
    [self addSubview:_tabSearchButton];
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
  tab.pageTitle = BroURLIsBlank(title) ? kBroBlankTabTitle : title;
  tab.target = self;
  tab.selectAction = @selector(tabSelected:);
  tab.closeAction = @selector(tabClosed:);
  [_tabs addObject:tab];
  [self addSubview:tab];

  // The new pill starts at its final slot fully transparent and fades in
  // while its neighbors and the "+" button slide over to make room.
  CGFloat tabWidth = [self fittedTabWidth];
  tab.frame = NSMakeRect((_tabs.count - 1) * (tabWidth + kTabGap), pillY,
                         tabWidth, kTabPillHeight);
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
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  draggingTab_ = tab;
  dragging_ = NO;
  dragStartX_ = p.x;
  dragOffsetX_ = p.x - tab.frame.origin.x;
}

- (void)dragTab:(BroTabView*)tab withEvent:(NSEvent*)event {
  if (tab != draggingTab_) {
    return;
  }
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
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
  BroTabView* activeTab = nil;
  for (BroTabView* tab in _tabs) {
    tab.isActive = (tab.browserId == browserId);
    if (tab.browserId == browserId) {
      activeTab = tab;
    }
  }

  // The active pill hosts the shared editable address field.
  if (g_toolbar) {
    NSTextField* addressField = g_toolbar.addressField;
    // CEF may report the already-active browser again while its field editor
    // is live. Re-parenting the same control in that state leaves AppKit's
    // window-owned editor visible while attachAddressField restores the
    // compact title, drawing both strings on top of each other. Keep same-tab
    // activation idempotent; for a real switch, finish editing before moving
    // the shared field to its new pill.
    if (addressField.superview != activeTab) {
      if (addressField.currentEditor) {
        [self.window makeFirstResponder:nil];
      }
      [addressField removeFromSuperview];
      if (activeTab) {
        [activeTab attachAddressField:addressField];
      }
    }
    // The viewport toggles reflect the active tab's own emulation state.
    [g_toolbar setViewportMode:TabIsMobile(browserId)];
  }

  // In a collapsed strip the newly active pill grows out of its square so its
  // URL can be read and typed, and the one it replaced shrinks back. The same
  // swap happens around a pinned pill in a roomy strip (square inactive,
  // expanded active). Animate it; with no pins and room for everyone, every
  // pill is already the same width and there is nothing to move.
  if (([self isCollapsed] || [self pinnedCount] > 0) && !dragging_) {
    BroRunLayoutSpring(^{
      [self applyTabLayout:YES];
    }, nil);
  }
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
  // The right edge reserves the trailing "+" button and the pinned search
  // button (toolbar-button sized).
  return self.frame.size.width - (kAddTabButtonSize + 8.0) -
         (kButtonSize + 8.0);
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

// Pinned pills that render as squares: all of them except an active one,
// which expands so the hosted address field stays usable.
- (NSUInteger)squarePinnedCount {
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

// Strip width left for expandable pills once the pinned squares took theirs.
- (CGFloat)expandableStripWidth {
  return [self availableStripWidth] -
         (CGFloat)[self squarePinnedCount] * (kTabPillSquareWidth + kTabGap);
}

// Fits expandable pills to the remaining strip width (minus the "+" button
// and the pinned squares), capped at the mockup's pill width. Only meaningful
// while the strip is roomy — once pills would go narrower than
// kTabPillTextMinWidth the layout switches to squares and this stops
// describing every pill (see -tabWidths).
- (CGFloat)fittedTabWidth {
  NSUInteger count = MAX(_tabs.count - [self squarePinnedCount], (NSUInteger)1);
  CGFloat fitWidth = [self expandableStripWidth] / count - kTabGap;
  return MIN(MAX(fitWidth, kTabPillSquareWidth), kTabPillMaxWidth);
}

// YES once an even split would leave no room for text: pills become squares.
- (BOOL)isCollapsed {
  NSUInteger count = MAX(_tabs.count - [self squarePinnedCount], (NSUInteger)1);
  return [self expandableStripWidth] / count - kTabGap < kTabPillTextMinWidth;
}

// Width of one drag slot for `tab`. Pinned pills only travel their group of
// squares. Collapsed (or pinned), the pills the dragged pill travels past are
// squares, so slots are square-sized even though the carried pill may not be.
- (CGFloat)dragSlotWidthForTab:(BroTabView*)tab {
  return (tab.pinned || [self isCollapsed] ? kTabPillSquareWidth
                                           : [self fittedTabWidth]) +
         kTabGap;
}

// Per-pill widths in strip order. Pinned inactive pills are always squares;
// the rest are uniform while there is room. Collapsed, every inactive pill is
// a square and the active one takes the leftover space so its URL stays
// readable and editable.
- (NSArray<NSNumber*>*)tabWidths {
  NSMutableArray<NSNumber*>* widths =
      [NSMutableArray arrayWithCapacity:_tabs.count];
  if (![self isCollapsed]) {
    CGFloat uniform = [self fittedTabWidth];
    for (BroTabView* tab in _tabs) {
      [widths addObject:@(tab.pinned && !tab.isActive ? kTabPillSquareWidth
                                                      : uniform)];
    }
    return widths;
  }
  CGFloat squares =
      (CGFloat)(_tabs.count - 1) * (kTabPillSquareWidth + kTabGap);
  CGFloat slack = [self availableStripWidth] - squares - kTabGap;
  // Open the active pill to the full pill width when the slack allows, so the
  // URL has as much room to be typed as it would in a roomy strip. Below the
  // comfortable minimum expanding buys nothing readable, so it stays square.
  CGFloat activeWidth = slack >= kTabPillMinWidth
                            ? MIN(kTabPillMaxWidth, slack)
                            : kTabPillSquareWidth;
  for (BroTabView* tab in _tabs) {
    [widths addObject:@(tab.isActive ? activeWidth : kTabPillSquareWidth)];
  }
  return widths;
}

// Positions pills and the "+" button. When `animated`, frames move through
// the animator proxy, so this must run inside an NSAnimationContext group.
- (void)applyTabLayout:(BOOL)animated {
  CGFloat pillY = (self.frame.size.height - kTabPillHeight) / 2.0;
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
    } else if (animated) {
      tab.animator.frame = target;
    } else {
      tab.frame = target;
    }
    // The split pair overlaps by 1pt so the two borders coincide and the
    // pair reads as one continuous pill; every other neighbor keeps the
    // normal gap.
    x += tabWidth - (tab.joinedSide == 1 ? kSplitJoinedOverlap : -kTabGap);
  }

  NSRect addTarget =
      NSMakeRect(x, (self.frame.size.height - kAddTabButtonSize) / 2.0,
                 kAddTabButtonSize, kAddTabButtonSize);
  if (animated) {
    _addTabButton.animator.frame = addTarget;
  } else {
    _addTabButton.frame = addTarget;
  }

  // The search button never trails the pills; it stays pinned at the right
  // edge.
  _tabSearchButton.frame =
      NSMakeRect(self.frame.size.width - kButtonSize,
                 (self.frame.size.height - kButtonSize) / 2.0,
                 kButtonSize, kButtonSize);
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
    // Clicking the active pill starts editing its URL.
    if (g_toolbar) {
      [g_toolbar focusAddressField];
    }
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
  if (hoverCard_ && !hoverCard_.hidden) {
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
        if (!bar || !hoveredTab || hoveredTab.superview != bar) {
          return;
        }
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
        [weakSelf hideHoverCard];
      }];
}

- (void)hideHoverCard {
  [hoverCardTimer_ invalidate];
  hoverCardTimer_ = nil;
  [hoverCardHideTimer_ invalidate];
  hoverCardHideTimer_ = nil;
  BroOverlayHide(hoverCard_);
  hoverCardTabId_ = -1;
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
  pin.toolTip = tab.pinned ? @"Unpin Tab" : @"Pin Tab";
  pin.accessibilityLabel = pin.toolTip;
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
  split.toolTip = isPane ? @"Exit Split Screen" : @"Split Screen";
  split.accessibilityLabel = split.toolTip;
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
  hoverCardTabId_ = tab.browserId;
  [self configureHoverCardButtonsForTab:tab];

  // The card matches the hovered pill's width, reading as a dropdown of the
  // pill; collapsed squares get the pill minimum so the text stays legible.
  CGFloat width = MIN(MAX(NSWidth(tab.frame), kTabPillMinWidth),
                      NSWidth(container.bounds) - 16.0);
  if (width < 100.0) {
    return;  // window too narrow for a useful card
  }
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
  if (!container || tab.superview != self) {
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
