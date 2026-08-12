// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "include/cef_browser.h"
#include "bro_handler.h"
#import "bro_mac_internal.h"
#import "bro_motion.h"
#import "radix_icons.h"

#pragma mark - BroToolbar

// g_toolbar is declared extern in bro_mac_internal.h.
BroToolbar* g_toolbar = nil;

// Resolves what the user typed into a loadable URL: safe schemes pass
// through, about: passes through, a dotted word gets https://, and anything
// else becomes a Google search. Shared by the address field and the command
// palette's fallback row (which shows the classification before navigating).
// Declared extern in bro_mac_internal.h. |query| must already be trimmed;
// returns nil for an empty query.
NSString* BroResolveQueryToURL(NSString* query) {
  if (query.length == 0) {
    return nil;
  }
  NSString* lower = query.lowercaseString;

  if ([query containsString:@"://"]) {
    // Only navigate to safe schemes; anything else (javascript:, data:, ...)
    // falls through to search.
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"] ||
        [lower hasPrefix:@"file://"]) {
      return query;
    }
  } else if ([lower hasPrefix:@"about:"]) {
    return query;
  } else if ([query containsString:@"."] && ![query containsString:@" "]) {
    return [@"https://" stringByAppendingString:query];
  }

  // Treat as search query. Encode everything outside the unreserved set so
  // characters like & and + can't alter the query string.
  NSMutableCharacterSet* allowed = [NSMutableCharacterSet alphanumericCharacterSet];
  [allowed addCharactersInString:@"-._~"];
  NSString* encoded = [query stringByAddingPercentEncodingWithAllowedCharacters:allowed];
  return [NSString stringWithFormat:@"https://www.google.com/search?q=%@",
                                    encoded ?: @""];
}

// BroAddressField's @interface is declared in bro_mac_internal.h (shared
// with bro_mac.mm, where BroTabView checks isKindOfClass:[BroAddressField
// class]). BroToolbar's @interface is declared there too (shared with
// bro_downloads.mm, which reads .downloadsButton).

@implementation BroAddressField

// While idle the field is click-through: the pill underneath owns the mouse,
// so the active tab can be dragged to reorder from anywhere on its surface,
// and a plain click focuses the field on mouse-up (selecting the whole URL,
// like other browsers). Once editing starts, the field editor takes over and
// the mouse behaves like a normal text field.
- (NSView*)hitTest:(NSPoint)point {
  if (!self.currentEditor) {
    return nil;
  }
  return [super hitTest:point];
}

- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok && [self.delegate isKindOfClass:[BroToolbar class]]) {
    [(BroToolbar*)self.delegate addressFieldDidFocus:self];
  }
  return ok;
}

@end

@implementation BroToolbar {
  // Hover zone spanning the search + downloads buttons; both stay hidden
  // (alpha 0) until the pointer enters it.
  NSTrackingArea* revealTrackingArea_;
  BOOL revealZoneHovered_;
  BOOL trailingGroupFocused_;
  __weak BroHoverButton* tabSearchButton_;
  NSArray<BroHoverButton*>* trailingButtons_;
  // Invalidates a pending auto-hide scheduled by pulseDownloadsButton.
  NSUInteger revealGeneration_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    // Performance: Enable layer-backing for GPU compositing
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

    // Navigation buttons, inline with the traffic lights.
    CGFloat x = kTrafficLightInset;
    CGFloat y = (frame.size.height - kButtonSize) / 2.0;

    _backButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                         icon:RadixIconArrowLeft
                                       action:@selector(goBack:)
                                        label:@"Back"
                                keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey]
                                 modifierMask:NSEventModifierFlagCommand];
    [self addSubview:_backButton];
    x += kButtonSize + kButtonSpacing;

    _forwardButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                            icon:RadixIconArrowRight
                                          action:@selector(goForward:)
                                           label:@"Forward"
                                   keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey]
                                    modifierMask:NSEventModifierFlagCommand];
    [self addSubview:_forwardButton];
    x += kButtonSize + kButtonSpacing;

    _refreshButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                            icon:RadixIconReload
                                          action:@selector(refresh:)
                                           label:@"Reload Page"
                                   keyEquivalent:@"r"
                                    modifierMask:NSEventModifierFlagCommand];
    [self addSubview:_refreshButton];

    _navigationHighlightGroup =
        [[BroHoverHighlightGroup alloc] initWithContainerView:self];
    _backButton.highlightGroup = _navigationHighlightGroup;
    _forwardButton.highlightGroup = _navigationHighlightGroup;
    _refreshButton.highlightGroup = _navigationHighlightGroup;

    // Viewport mode toggles pinned to the right edge. Exposed as a radio
    // group: exactly one of desktop/mobile is selected at a time.
    CGFloat rightX = BroTrailingControlX(frame.size.width, 0);
    _mobileButton = [self createButtonWithFrame:NSMakeRect(rightX, y, kButtonSize, kButtonSize)
                                           icon:RadixIconMobile
                                         action:@selector(selectMobileMode:)
                                          label:@"Mobile Viewport"
                                  keyEquivalent:@"m"
                                   modifierMask:NSEventModifierFlagCommand |
                                                NSEventModifierFlagShift];
    _mobileButton.autoresizingMask = NSViewMinXMargin;
    [_mobileButton setAccessibilityRole:NSAccessibilityRadioButtonRole];
    [self addSubview:_mobileButton];
    rightX = BroTrailingControlX(frame.size.width, 1);
    _desktopButton = [self createButtonWithFrame:NSMakeRect(rightX, y, kButtonSize, kButtonSize)
                                            icon:RadixIconDesktop
                                          action:@selector(selectDesktopMode:)
                                           label:@"Desktop Viewport"
                                   keyEquivalent:@"d"
                                    modifierMask:NSEventModifierFlagCommand |
                                                 NSEventModifierFlagShift];
    _desktopButton.autoresizingMask = NSViewMinXMargin;
    [_desktopButton setAccessibilityRole:NSAccessibilityRadioButtonRole];
    [self addSubview:_desktopButton];
    // Downloads sits left of the viewport radio group at the same spacing —
    // the four trailing icons (search, downloads, desktop, mobile) read as
    // one evenly spaced cluster.
    rightX = BroTrailingControlX(frame.size.width, 2);
    _downloadsButton = [self createButtonWithFrame:NSMakeRect(rightX, y, kButtonSize, kButtonSize)
                                              icon:RadixIconDownload
                                            action:@selector(toggleDownloads:)
                                             label:@"Downloads"
                                     keyEquivalent:@"j"
                                      modifierMask:NSEventModifierFlagCommand |
                                                   NSEventModifierFlagShift];
    _downloadsButton.autoresizingMask = NSViewMinXMargin;
    // Hidden until the pointer enters the shared reveal zone (see
    // updateTrackingAreas), together with the tab strip's search button.
    _downloadsButton.alphaValue = 0.0;
    [self addSubview:_downloadsButton];
    _trailingHighlightGroup =
        [[BroHoverHighlightGroup alloc] initWithContainerView:self];
    _downloadsButton.highlightGroup = _trailingHighlightGroup;
    _desktopButton.highlightGroup = _trailingHighlightGroup;
    _mobileButton.highlightGroup = _trailingHighlightGroup;
    trailingButtons_ = @[ _downloadsButton, _desktopButton, _mobileButton ];
    [self setViewportMode:NO];

    // Initial button states
    _backButton.enabled = NO;
    _forwardButton.enabled = NO;
  }
  return self;
}

- (BroHoverButton*)createButtonWithFrame:(NSRect)frame
                                    icon:(RadixIcon)icon
                                  action:(SEL)action
                                   label:(NSString*)label
                           keyEquivalent:(NSString*)keyEquivalent
                            modifierMask:(NSEventModifierFlags)modifierMask {
  BroHoverButton* button = [[BroHoverButton alloc] initWithFrame:frame];
  button.bezelStyle = NSBezelStyleTexturedRounded;
  button.bordered = NO;
  button.title = @"";
  button.image = RadixIconImage(icon, 15);
  button.imagePosition = NSImageOnly;
  button.contentTintColor = [NSColor labelColor];
  button.target = self;
  button.action = action;
  [button configureActionLabel:label
                 keyEquivalent:keyEquivalent
                  modifierMask:modifierMask];
  return button;
}

- (void)layoutTrailingControls {
  CGFloat y = (NSHeight(self.bounds) - kButtonSize) / 2.0;
  _mobileButton.frame = NSMakeRect(BroTrailingControlX(NSWidth(self.bounds), 0),
                                   y, kButtonSize, kButtonSize);
  _desktopButton.frame = NSMakeRect(BroTrailingControlX(NSWidth(self.bounds), 1),
                                    y, kButtonSize, kButtonSize);
  _downloadsButton.frame = NSMakeRect(BroTrailingControlX(NSWidth(self.bounds), 2),
                                      y, kButtonSize, kButtonSize);
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  [self layoutTrailingControls];
  [self updateTrackingAreas];
}

- (BOOL)isTrailingControlFirstResponder {
  NSResponder* responder = self.window.firstResponder;
  return [responder isKindOfClass:[BroHoverButton class]] &&
         [trailingButtons_ containsObject:(BroHoverButton*)responder];
}

- (void)trailingButton:(BroHoverButton*)button focusChanged:(BOOL)focused {
  revealGeneration_++;
  if (focused) {
    trailingGroupFocused_ = YES;
    [self setSearchDownloadsRevealed:YES];
    return;
  }
  __weak BroToolbar* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BroToolbar* toolbar = weakSelf;
    if (!toolbar) {
      return;
    }
    toolbar->trailingGroupFocused_ =
        [toolbar isTrailingControlFirstResponder];
    if (!toolbar->trailingGroupFocused_ && !toolbar->revealZoneHovered_) {
      [toolbar setSearchDownloadsRevealed:NO];
    }
  });
}

- (void)registerTabSearchButton:(BroHoverButton*)button {
  if (!button || tabSearchButton_ == button) {
    return;
  }
  tabSearchButton_ = button;
  button.highlightGroup = _trailingHighlightGroup;
  trailingButtons_ =
      @[ button, _downloadsButton, _desktopButton, _mobileButton ];
  __weak BroToolbar* weakSelf = self;
  for (BroHoverButton* trailingButton in trailingButtons_) {
    trailingButton.focusChangedHandler =
        ^(BroHoverButton* focusedButton, BOOL focused) {
      [weakSelf trailingButton:focusedButton focusChanged:focused];
    };
  }
  [self updateTrackingAreas];
}

#pragma mark - Search/downloads hover reveal

// One tracking rect covers both hideable icons — the tab strip's search
// button and the downloads button — plus the gap between them, full toolbar
// height, so the pair reveals as soon as the pointer nears either. The rect
// is explicit (not InVisibleRect) because it spans a subview of a sibling;
// AppKit re-invokes this on geometry changes, and bro_mac.mm calls it once
// more after the tab bar exists.
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (revealTrackingArea_) {
    [self removeTrackingArea:revealTrackingArea_];
    revealTrackingArea_ = nil;
  }
  NSRect zone = NSUnionRect(_downloadsButton.frame, _mobileButton.frame);
  NSView* searchButton = tabSearchButton_ ?: g_tab_bar.tabSearchButton;
  if (searchButton && searchButton.window == self.window) {
    zone = NSUnionRect(zone,
                       [self convertRect:searchButton.bounds
                                fromView:searchButton]);
  }
  zone = NSInsetRect(zone, -8.0, 0);
  zone.origin.y = 0;
  zone.size.height = NSHeight(self.bounds);
  revealTrackingArea_ = [[NSTrackingArea alloc]
      initWithRect:zone
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
             owner:self
          userInfo:nil];
  [self addTrackingArea:revealTrackingArea_];
}

- (void)setSearchDownloadsRevealed:(BOOL)revealed {
  CGFloat alpha = revealed ? 1.0 : 0.0;
  NSView* searchButton = tabSearchButton_ ?: g_tab_bar.tabSearchButton;
  if (BroMotionReduced()) {
    _downloadsButton.alphaValue = alpha;
    searchButton.alphaValue = alpha;
    return;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = kCloseButtonFadeDuration;
    _downloadsButton.animator.alphaValue = alpha;
    searchButton.animator.alphaValue = alpha;
  }];
}

- (void)mouseEntered:(NSEvent*)event {
  revealZoneHovered_ = YES;
  [self setSearchDownloadsRevealed:YES];
}

- (void)mouseExited:(NSEvent*)event {
  revealZoneHovered_ = NO;
  if (!trailingGroupFocused_) {
    [self setSearchDownloadsRevealed:NO];
  }
}

// Nudge when a download starts or finishes. With the icons hidden at rest,
// the nudge is the reveal itself: fade the pair in, then back out unless
// the pointer is in the zone. If they're already revealed, fall back to the
// original opacity dip on the downloads button. Declared in
// bro_mac_internal.h; called from bro_downloads.mm.
- (void)pulseDownloadsButton {
  revealGeneration_++;
  NSUInteger generation = revealGeneration_;
  if (revealZoneHovered_ || trailingGroupFocused_) {
    if (!BroMotionReduced()) {
      _downloadsButton.alphaValue = 0.25;
      [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = 0.5;
        _downloadsButton.animator.alphaValue = 1.0;
      }];
    }
    return;
  }
  [self setSearchDownloadsRevealed:YES];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (generation == revealGeneration_ && !revealZoneHovered_ &&
            !trailingGroupFocused_) {
          [self setSearchDownloadsRevealed:NO];
        }
      });
}

#pragma mark - Navigation Actions

- (void)goBack:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser && browser->CanGoBack()) {
      browser->GoBack();
    }
  }
}

- (void)goForward:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser && browser->CanGoForward()) {
      browser->GoForward();
    }
  }
}

- (void)refresh:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      browser->Reload();
    }
  }
}

- (void)navigateToURL:(NSString*)urlString {
  urlString = [urlString stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString* target = BroResolveQueryToURL(urlString);
  if (!target) return;

  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      // Show the destination immediately; OnAddressChange confirms it later.
      BroTabView* tab = [g_tab_bar tabWithBrowserId:browser->GetIdentifier()];
      [tab setTabURL:target];
      browser->GetMainFrame()->LoadURL([target UTF8String]);
    }
  }
}

#pragma mark - Toolbar Actions

- (void)toggleDownloads:(id)sender {
  BroToggleDownloadsPopover();
}

- (void)selectMobileMode:(id)sender {
  [self applyViewportMode:YES];
}

- (void)selectDesktopMode:(id)sender {
  [self applyViewportMode:NO];
}

// Applies the viewport mode to the ACTIVE tab only.
- (void)applyViewportMode:(BOOL)mobile {
  BroHandler* handler = BroHandler::GetInstance();
  if (!handler) {
    return;
  }
  int activeId = handler->GetActiveBrowserId();
  if (activeId < 0 || handler->IsTabMobile(activeId) == (bool)mobile) {
    return;
  }
  handler->SetTabMobileEmulation(activeId, mobile);  // CDP overrides only
  [self setViewportMode:mobile];
  // Reload (needed for the user agent override to take effect) only after the
  // animation settles, so the page load doesn't stutter the transition. A
  // superseded animation drops its completion, coalescing rapid toggles into
  // a single reload with the final state.
  UpdateWindowForViewportMode(mobile, YES, ^{
    BroHandler* h = BroHandler::GetInstance();
    if (h) {
      h->ReloadTab(activeId);
    }
  });
}

- (void)setViewportMode:(BOOL)mobile {
  NSColor* active = [NSColor labelColor];
  NSColor* inactive = [NSColor tertiaryLabelColor];
  _desktopButton.contentTintColor = mobile ? inactive : active;
  _mobileButton.contentTintColor = mobile ? active : inactive;
  _desktopButton.selectedState = !mobile;
  _mobileButton.selectedState = mobile;

  // Keep both radio buttons focusable so hover/focus motion is identical.
  // applyViewportMode: already makes choosing the current mode a no-op.
  _desktopButton.enabled = YES;
  _mobileButton.enabled = YES;
}

#pragma mark - NSTextFieldDelegate

- (BOOL)configureAddressFieldEditor:(BroAddressField*)field {
  NSTextView* editor = (NSTextView*)[field currentEditor];
  if (![editor isKindOfClass:[NSTextView class]]) {
    return NO;
  }

  NSFont* font = BroUIFont(kTabTextFontSize);
  editor.font = font;
  editor.insertionPointColor = [NSColor labelColor];
  editor.textColor = [NSColor labelColor];
  editor.drawsBackground = NO;

  // NSTextView adds five points of line-fragment padding by default. The
  // resting Core Text renderer starts at x=0, so leaving that default in
  // place makes the selected URL jump right on focus even though both views
  // have the same frame. Remove every editor-owned inset explicitly.
  editor.textContainer.lineFragmentPadding = 0.0;

  // Use the exact Core Text baseline equation from BroShimmerTextView. AppKit's
  // cell reports a 13pt height for Geist 10 while Core Text's pixel-aligned
  // line box is 14pt; centering the cell therefore puts selected text 1pt
  // above the resting host. Deriving the editor inset from the same font
  // metrics keeps both renderers on precisely the same baseline.
  CGFloat lineHeight =
      ceil(font.ascender - font.descender + font.leading);
  CGFloat baselineFromBottom = ceil(-font.descender);
  CGFloat baselineFromTop =
      (field.bounds.size.height + lineHeight) / 2.0 -
      baselineFromBottom;
  editor.textContainerInset =
      NSMakeSize(0.0, MAX(0.0, baselineFromTop - font.ascender));

  // Selection inverts against whichever treatment Regular glass resolves:
  // semantic label and background colors stay legible in both variants.
  editor.selectedTextAttributes = @{
    NSBackgroundColorAttributeName : [NSColor labelColor],
    NSForegroundColorAttributeName : [NSColor textBackgroundColor],
  };
  [editor selectAll:nil];
  return YES;
}

- (void)addressFieldDidFocus:(BroAddressField*)field {
  BroTabView* tab = field.owningTab;
  if (!tab || !tab.isActive) {
    return;
  }
  // Show the full URL for editing; the host pill shows the focused look
  // (adaptive hairline border and primary text) from click-in through typing.
  field.stringValue = BroURLIsBlank(tab.tabURL) ? @"" : tab.tabURL;
  tab.editingAddress = YES;
  // Configure synchronously so AppKit never presents one frame with its
  // default font/insets before snapping to the shared tab metrics. Some
  // responder paths install the field editor just after becomeFirstResponder;
  // retain a one-turn fallback only for those paths.
  if (![self configureAddressFieldEditor:field]) {
    __weak BroAddressField* weakField = field;
    dispatch_async(dispatch_get_main_queue(), ^{
      BroAddressField* strongField = weakField;
      if (strongField) {
        [self configureAddressFieldEditor:strongField];
      }
    });
  }
}

- (void)controlTextDidBeginEditing:(NSNotification*)notification {
  if ([notification.object isKindOfClass:[BroAddressField class]]) {
    [self configureAddressFieldEditor:(BroAddressField*)notification.object];
  }
}

- (void)controlTextDidEndEditing:(NSNotification*)notification {
  if (![notification.object isKindOfClass:[BroAddressField class]]) {
    return;
  }
  BroAddressField* field = (BroAddressField*)notification.object;
  BroTabView* tab = field.owningTab;
  NSNumber* reason = notification.userInfo[@"NSTextMovement"];
  if (tab.isActive && reason &&
      reason.integerValue == NSReturnTextMovement) {
    [self navigateToURL:field.stringValue];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.window makeFirstResponder:nil];
    });
  }
  tab.editingAddress = NO;
}

- (void)focusAddressField {
  BroHandler* handler = BroHandler::GetInstance();
  int activeId = handler ? handler->GetActiveBrowserId() : -1;
  [[g_tab_bar tabWithBrowserId:activeId] focusAddressField];
}

#pragma mark - State Updates

- (void)updateNavigationState:(BOOL)canGoBack canGoForward:(BOOL)canGoForward {
  _backButton.enabled = canGoBack;
  _forwardButton.enabled = canGoForward;
}

- (void)updateURL:(NSString*)url {
  // Blank pages keep the field empty rather than showing "about:blank".
  if (BroURLIsBlank(url)) {
    url = @"";
  }
  BroHandler* handler = BroHandler::GetInstance();
  int activeId = handler ? handler->GetActiveBrowserId() : -1;
  [[g_tab_bar tabWithBrowserId:activeId] setTabURL:url ?: @""];
}

@end
