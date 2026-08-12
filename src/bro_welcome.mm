// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The welcome (new-tab) state: a dimmed app mark and a time-of-day greeting
// above one large glass search input, centered over the window's glass
// shell. Blank tabs keep
// their CEF container detached (see UpdateTabContainerVisibility), so this
// view has the browser area to itself and is the only place a URL can be
// typed for a blank tab -- the tab pills show plain labels and the command
// palette covers navigation from loaded pages.

#import "bro_mac_internal.h"
#import "bro_motion.h"

#pragma mark - BroWelcomeView

static const CGFloat kWelcomeInputMaxWidth = 640.0;
static const CGFloat kWelcomeInputHeight = 54.0;
// Minimum horizontal inset each side in narrow windows (mobile shell).
static const CGFloat kWelcomeInputMargin = 24.0;
static const CGFloat kWelcomeLogoSize = 64.0;
// Dimmed so the mark reads as a watermark, not a control.
static const CGFloat kWelcomeLogoAlpha = 0.55;
static const CGFloat kWelcomeFontSize = 15.0;
static const CGFloat kWelcomeFieldInsetX = 20.0;
// The group's vertical center sits slightly above the container's center,
// where an empty page's focal point reads as balanced.
static const CGFloat kWelcomeCenterFraction = 0.58;
static const NSTimeInterval kWelcomeFadeDuration = 0.2;
// Greeting between the logo and the input.
static const CGFloat kWelcomeGreetingFontSize = 20.0;
static const CGFloat kWelcomeGreetingHeight = 26.0;
static const CGFloat kWelcomeLogoGreetingGap = 20.0;
static const CGFloat kWelcomeGreetingInputGap = 24.0;

@interface BroWelcomeView : NSView <NSTextFieldDelegate>
- (void)focusInput;
- (void)clearInput;
- (void)refreshGreeting;
// Hands keyboard focus back if the input's editor still holds it, so a
// hidden welcome view never keeps typing focus (same contract as
// -[BroCommandPalette restoreFocusIfNeeded]).
- (void)releaseFocusIfHeld;
@end

@implementation BroWelcomeView {
  NSImageView* logoView_;
  NSTextField* greeting_;
  NSView* inputPanel_;
  NSTextField* field_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.accessibilityRole = NSAccessibilityGroupRole;
    self.accessibilityLabel = kBroBlankTabTitle;

    logoView_ = [[NSImageView alloc] initWithFrame:NSZeroRect];
    logoView_.image = [NSApp applicationIconImage];
    logoView_.imageScaling = NSImageScaleProportionallyUpOrDown;
    logoView_.alphaValue = kWelcomeLogoAlpha;
    logoView_.accessibilityElement = NO;
    [self addSubview:logoView_];

    greeting_ = BroHoverCardLabel(BroUIFontBold(kWelcomeGreetingFontSize), 1.0);
    greeting_.textColor = [NSColor labelColor];
    greeting_.alignment = NSTextAlignmentCenter;
    [self addSubview:greeting_];
    [self refreshGreeting];

    inputPanel_ = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, kWelcomeInputMaxWidth,
                                 kWelcomeInputHeight)];
    inputPanel_.wantsLayer = YES;
    inputPanel_.layer.cornerRadius = BroCornerRadiusForSize(
        BroSurfaceCornerRadius(), inputPanel_.bounds.size);
    BroApplyElevation(inputPanel_, BroElevationOverlay);
    NSView* contentHost =
        BroInstallGlassSurface(inputPanel_, inputPanel_.layer.cornerRadius);
    [self addSubview:inputPanel_];

    field_ = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field_.font = BroUIFont(kWelcomeFontSize);
    field_.textColor = [NSColor labelColor];
    field_.bordered = NO;
    field_.bezeled = NO;
    field_.drawsBackground = NO;
    field_.focusRingType = NSFocusRingTypeNone;
    field_.cell.usesSingleLineMode = YES;
    field_.cell.scrollable = YES;
    field_.delegate = self;
    // Return commits through the field's action. The action path also serves
    // accessibility's AXConfirm, which bypasses the field editor's
    // insertNewline: entirely. Explicitly never on focus loss: a tab switch
    // mid-typing must not navigate the newly active tab.
    field_.cell.sendsActionOnEndEditing = NO;
    field_.target = self;
    field_.action = @selector(commitInput:);
    field_.placeholderAttributedString = [[NSAttributedString alloc]
        initWithString:@"Search or type a URL"
            attributes:@{
              NSFontAttributeName : BroUIFont(kWelcomeFontSize),
              NSForegroundColorAttributeName : [NSColor tertiaryLabelColor],
            }];
    field_.accessibilityLabel = @"Search or type a URL";
    [contentHost addSubview:field_];

    [self layoutContents];
  }
  return self;
}

// The greeting tracks the clock, not the moment the view was built: the
// window routinely stays open across a morning/afternoon boundary, so it is
// refreshed on every show.
- (void)refreshGreeting {
  NSInteger hour = [[NSCalendar currentCalendar] component:NSCalendarUnitHour
                                                  fromDate:[NSDate date]];
  NSString* text = @"Good evening";
  if (hour >= 5 && hour < 12) {
    text = @"Good morning";
  } else if (hour >= 12 && hour < 18) {
    text = @"Good afternoon";
  }
  greeting_.stringValue = text;
  [self layoutContents];
}

- (void)layoutContents {
  NSRect bounds = self.bounds;
  CGFloat panelWidth = MAX(
      0.0, MIN(kWelcomeInputMaxWidth,
               NSWidth(bounds) - 2.0 * kWelcomeInputMargin));
  CGFloat groupHeight = kWelcomeLogoSize + kWelcomeLogoGreetingGap +
                        kWelcomeGreetingHeight + kWelcomeGreetingInputGap +
                        kWelcomeInputHeight;
  CGFloat panelY = round(NSHeight(bounds) * kWelcomeCenterFraction -
                         groupHeight / 2.0);
  inputPanel_.frame =
      NSMakeRect(round((NSWidth(bounds) - panelWidth) / 2.0), panelY,
                 panelWidth, kWelcomeInputHeight);
  greeting_.frame =
      NSMakeRect(round((NSWidth(bounds) - panelWidth) / 2.0),
                 panelY + kWelcomeInputHeight + kWelcomeGreetingInputGap,
                 panelWidth, kWelcomeGreetingHeight);
  logoView_.frame =
      NSMakeRect(round((NSWidth(bounds) - kWelcomeLogoSize) / 2.0),
                 NSMaxY(greeting_.frame) + kWelcomeLogoGreetingGap,
                 kWelcomeLogoSize, kWelcomeLogoSize);
  CGFloat fieldHeight =
      ceil([field_.cell cellSizeForBounds:NSMakeRect(0, 0, 1000, 100)].height);
  field_.frame = NSMakeRect(
      kWelcomeFieldInsetX,
      round((kWelcomeInputHeight - fieldHeight) / 2.0),
      MAX(0.0, panelWidth - 2.0 * kWelcomeFieldInsetX), fieldHeight);
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  [self layoutContents];
}

- (void)focusInput {
  [self.window makeFirstResponder:field_];
}

- (void)clearInput {
  field_.stringValue = @"";
}

- (void)releaseFocusIfHeld {
  NSWindow* window = self.window;
  NSResponder* responder = window.firstResponder;
  if ([responder isKindOfClass:[NSText class]] &&
      ((NSText*)responder).delegate == (id)field_) {
    [window makeFirstResponder:nil];
  }
}

- (void)commitInput:(id)sender {
  NSString* text = [field_.stringValue
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (text.length == 0) {
    return;
  }
  [g_toolbar navigateToURL:text];
  // The commit hides this view; release the editor a turn later so the
  // arriving page can take keyboard focus (mirrors the palette's hide).
  dispatch_async(dispatch_get_main_queue(), ^{
    [self releaseFocusIfHeld];
  });
}

- (BOOL)control:(NSControl*)control
               textView:(NSTextView*)textView
    doCommandBySelector:(SEL)commandSelector {
  if (control != field_) {
    return NO;
  }
  if (commandSelector == @selector(cancelOperation:)) {
    // A blank tab has no previous state to restore; Escape just clears.
    [self clearInput];
    return YES;
  }
  return NO;
}

@end

#pragma mark - Entry points

// The one welcome view, shared across every blank tab; nil until first shown
// and after teardown. The tab id tracks which blank tab the view currently
// fronts so switching between two blank tabs re-clears and re-focuses.
static BroWelcomeView* g_welcome_view = nil;
static int g_welcome_tab_id = -1;

// These are declared extern in bro_mac_internal.h.

BOOL BroWelcomeVisible(void) {
  return g_welcome_view && g_welcome_view.superview && !g_welcome_view.hidden;
}

void BroWelcomeSetVisible(BOOL visible, int activeBrowserId) {
  NSView* container = BroBrowserContainerView();
  if (!visible || !container) {
    if (BroWelcomeVisible()) {
      [g_welcome_view releaseFocusIfHeld];
      g_welcome_view.hidden = YES;
    }
    g_welcome_tab_id = -1;
    return;
  }

  BOOL wasVisible =
      BroWelcomeVisible() && g_welcome_view.superview == container;
  BOOL tabChanged = activeBrowserId != g_welcome_tab_id;
  g_welcome_tab_id = activeBrowserId;
  if (wasVisible && !tabChanged) {
    // Visibility updates run on every layout-affecting event; a no-change
    // call must not re-stack the view over transient overlays or yank
    // keyboard focus back from them.
    return;
  }

  if (!g_welcome_view) {
    g_welcome_view = [[BroWelcomeView alloc] initWithFrame:container.bounds];
    g_welcome_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
  if (!wasVisible) {
    // Re-add last on show so it composites above the page/glass transition
    // veil and the detached tab containers (see ShowCommandPalette).
    [g_welcome_view removeFromSuperview];
    g_welcome_view.frame = container.bounds;
    [container addSubview:g_welcome_view];
    g_welcome_view.hidden = NO;
    if (BroMotionReduced()) {
      g_welcome_view.alphaValue = 1.0;
    } else {
      g_welcome_view.alphaValue = 0.0;
      [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = kWelcomeFadeDuration;
        ctx.timingFunction = [CAMediaTimingFunction
            functionWithName:kCAMediaTimingFunctionEaseOut];
        g_welcome_view.animator.alphaValue = 1.0;
      }];
    }
  }

  // The input is the page's whole purpose, so it takes focus on every
  // arrival. Deferred a turn so browser adoption and layout settle before
  // AppKit installs its field editor; the guards keep rapid tab churn
  // deterministic (only the latest still-visible blank tab gets focus).
  [g_welcome_view clearInput];
  [g_welcome_view refreshGreeting];
  BroWelcomeView* view = g_welcome_view;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (view == g_welcome_view && g_welcome_tab_id == activeBrowserId &&
        BroWelcomeVisible()) {
      [view focusInput];
    }
  });
}

void BroWelcomeFocusInput(void) {
  if (BroWelcomeVisible()) {
    [g_welcome_view focusInput];
  }
}

void BroTeardownWelcome(void) {
  [g_welcome_view removeFromSuperview];
  g_welcome_view = nil;
  g_welcome_tab_id = -1;
}
