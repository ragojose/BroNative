// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <Cocoa/Cocoa.h>

#include <cmath>
#include <cstdlib>

#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "bro_app.h"
#include "bro_handler.h"
#import "radix_icons.h"

// Forward declarations
@class BroWindow;
@class BroToolbar;
@class BroTabBar;
@class BroTabView;

// Constants
static const CGFloat kToolbarHeight = 52.0;
static const CGFloat kButtonSize = 28.0;
static const CGFloat kButtonSpacing = 4.0;
static const CGFloat kTabPillMaxWidth = 300.0;
static const CGFloat kTabPillMinWidth = 110.0;
static const CGFloat kTabPillHeight = 32.0;
static const CGFloat kPillCornerRadius = 10.0;
static const CGFloat kTrafficLightInset = 100.0;
static const CGFloat kMobileViewportWidth = 390.0;

// Global references
static BroWindow* g_main_window = nil;
static BroToolbar* g_toolbar = nil;
static BroTabBar* g_tab_bar = nil;

// Map browser IDs to their container views
static NSMutableDictionary<NSNumber*, NSView*>* g_browser_views = nil;

// Containers created for incoming popup browsers, keyed by popup ID. Entries
// are removed when the popup's browser is adopted as a tab, or on abort.
static NSMutableDictionary<NSNumber*, NSView*>* g_pending_popup_containers = nil;

// Forward declaration of tab creation functions (implemented after BroWindow)
static void CreateNewBrowserTab(void);
static void CreateNewBrowserTabWithURL(const std::string& url);

// Reframes every per-tab container for its own viewport mode (mobile
// emulation is per-tab).
static void UpdateChromeLayout(void);

// True if the given tab has mobile emulation active.
static BOOL TabIsMobile(int browser_id) {
  BroHandler* handler = BroHandler::GetInstance();
  return handler && handler->IsTabMobile(browser_id);
}

#pragma mark - BroHoverButton

// Icon button with hover/pressed/selected backgrounds, a pointing-hand
// cursor, and keyboard focus (tabbable even when the system's Full Keyboard
// Access setting is off).
@interface BroHoverButton : NSButton
// Persistent "selected" background for toggle buttons (viewport modes).
@property (nonatomic, assign) BOOL selectedState;
@end

@implementation BroHoverButton {
  BOOL hovered_;
  BOOL pressed_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6.0;
    self.focusRingType = NSFocusRingTypeExterior;
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

- (void)drawFocusRingMask {
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds
                                   xRadius:self.layer.cornerRadius
                                   yRadius:self.layer.cornerRadius] fill];
}

- (NSRect)focusRingMaskBounds {
  return self.bounds;
}

- (void)refreshBackground {
  CGFloat alpha = 0.0;
  if (self.enabled) {
    if (pressed_) {
      alpha = 0.16;
    } else if (_selectedState) {
      alpha = hovered_ ? 0.14 : 0.10;
    } else if (hovered_) {
      alpha = 0.08;
    }
  }
  self.layer.backgroundColor =
      alpha > 0 ? [NSColor colorWithWhite:1.0 alpha:alpha].CGColor
                : [NSColor clearColor].CGColor;
}

- (void)setSelectedState:(BOOL)selectedState {
  _selectedState = selectedState;
  self.accessibilityValue = @(selectedState);
  [self refreshBackground];
}

- (void)setEnabled:(BOOL)enabled {
  [super setEnabled:enabled];
  [self refreshBackground];
  // Disabled buttons show the plain arrow cursor, not the pointing hand.
  [self.window invalidateCursorRectsForView:self];
}

- (void)resetCursorRects {
  if (self.enabled) {
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
  }
}

- (void)mouseEntered:(NSEvent*)event {
  hovered_ = YES;
  [self refreshBackground];
}

- (void)mouseExited:(NSEvent*)event {
  hovered_ = NO;
  pressed_ = NO;
  [self refreshBackground];
}

- (void)mouseDown:(NSEvent*)event {
  if (!self.enabled) {
    return;
  }
  pressed_ = YES;
  [self refreshBackground];
  // Runs the tracking loop synchronously; returns after mouse-up.
  [super mouseDown:event];
  pressed_ = NO;
  [self refreshBackground];
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

#pragma mark - BroToolbar

// NSTextField subclass that tells the toolbar when it gains focus, so the
// pill can swap from host-only display to the full editable URL.
@interface BroAddressField : NSTextField
@end

@interface BroToolbar : NSView <NSTextFieldDelegate>
@property (nonatomic, strong) BroHoverButton* backButton;
@property (nonatomic, strong) BroHoverButton* forwardButton;
@property (nonatomic, strong) BroHoverButton* refreshButton;
@property (nonatomic, strong) NSTextField* addressField;
@property (nonatomic, strong) BroHoverButton* desktopButton;
@property (nonatomic, strong) BroHoverButton* mobileButton;
@property (nonatomic, copy) NSString* fullURL;
- (void)addressFieldDidFocus;
- (void)setViewportMode:(BOOL)mobile;
- (void)updateURL:(NSString*)url;
- (void)focusAddressField;
@end

@implementation BroAddressField

- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok && [self.delegate isKindOfClass:[BroToolbar class]]) {
    [(BroToolbar*)self.delegate addressFieldDidFocus];
  }
  return ok;
}

@end

@implementation BroToolbar

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    // Performance: Enable layer-backing for GPU compositing
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

    _fullURL = @"";

    // Navigation buttons, inline with the traffic lights.
    CGFloat x = kTrafficLightInset;
    CGFloat y = (frame.size.height - kButtonSize) / 2.0;

    _backButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                         icon:RadixIconArrowLeft
                                       action:@selector(goBack:)
                                        label:@"Back"];
    [self addSubview:_backButton];
    x += kButtonSize + kButtonSpacing;

    _forwardButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                            icon:RadixIconArrowRight
                                          action:@selector(goForward:)
                                           label:@"Forward"];
    [self addSubview:_forwardButton];
    x += kButtonSize + kButtonSpacing;

    _refreshButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                            icon:RadixIconReload
                                          action:@selector(refresh:)
                                           label:@"Reload page"];
    [self addSubview:_refreshButton];

    // The editable address field lives inside the ACTIVE tab pill (the tab
    // strip re-parents it on tab switches); created here without a superview.
    _addressField = [[BroAddressField alloc] initWithFrame:NSMakeRect(0, 0, 100, 18)];
    _addressField.font = [NSFont systemFontOfSize:12.0];
    _addressField.bezeled = NO;
    _addressField.bordered = NO;
    _addressField.drawsBackground = NO;
    _addressField.focusRingType = NSFocusRingTypeNone;
    _addressField.textColor = [NSColor labelColor];
    _addressField.placeholderString = @"Enter URL or search";
    _addressField.delegate = self;
    _addressField.cell.scrollable = YES;
    _addressField.cell.usesSingleLineMode = YES;
    _addressField.accessibilityLabel = @"Address and search bar";

    // Viewport mode toggles pinned to the right edge. Exposed as a radio
    // group: exactly one of desktop/mobile is selected at a time.
    CGFloat rightX = frame.size.width - 12.0 - kButtonSize;
    _mobileButton = [self createButtonWithFrame:NSMakeRect(rightX, y, kButtonSize, kButtonSize)
                                           icon:RadixIconMobile
                                         action:@selector(selectMobileMode:)
                                          label:@"Mobile viewport"];
    _mobileButton.autoresizingMask = NSViewMinXMargin;
    [_mobileButton setAccessibilityRole:NSAccessibilityRadioButtonRole];
    [self addSubview:_mobileButton];
    rightX -= kButtonSize + kButtonSpacing;
    _desktopButton = [self createButtonWithFrame:NSMakeRect(rightX, y, kButtonSize, kButtonSize)
                                            icon:RadixIconDesktop
                                          action:@selector(selectDesktopMode:)
                                           label:@"Desktop viewport"];
    _desktopButton.autoresizingMask = NSViewMinXMargin;
    [_desktopButton setAccessibilityRole:NSAccessibilityRadioButtonRole];
    [self addSubview:_desktopButton];
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
                                   label:(NSString*)label {
  BroHoverButton* button = [[BroHoverButton alloc] initWithFrame:frame];
  button.bezelStyle = NSBezelStyleTexturedRounded;
  button.bordered = NO;
  button.title = @"";
  button.image = RadixIconImage(icon, 15);
  button.imagePosition = NSImageOnly;
  button.contentTintColor = [NSColor colorWithWhite:1.0 alpha:0.85];
  button.target = self;
  button.action = action;
  button.accessibilityLabel = label;
  button.toolTip = label;
  return button;
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
  if (urlString.length == 0) return;

  NSString* lower = urlString.lowercaseString;
  NSString* target = nil;

  if ([urlString containsString:@"://"]) {
    // Only navigate to safe schemes; anything else (javascript:, data:, ...)
    // falls through to search.
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"] ||
        [lower hasPrefix:@"file://"]) {
      target = urlString;
    }
  } else if ([lower hasPrefix:@"about:"]) {
    target = urlString;
  } else if ([urlString containsString:@"."] && ![urlString containsString:@" "]) {
    target = [@"https://" stringByAppendingString:urlString];
  }

  if (!target) {
    // Treat as search query. Encode everything outside the unreserved set so
    // characters like & and + can't alter the query string.
    NSMutableCharacterSet* allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-._~"];
    NSString* encoded = [urlString stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    target = [NSString stringWithFormat:@"https://www.google.com/search?q=%@", encoded ?: @""];
  }

  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      // Show the destination immediately; OnAddressChange confirms it later.
      self.fullURL = target;
      browser->GetMainFrame()->LoadURL([target UTF8String]);
    }
  }
}

#pragma mark - Toolbar Actions

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
  handler->SetTabMobileEmulation(activeId, mobile);
  [self setViewportMode:mobile];
  UpdateChromeLayout();
}

- (void)setViewportMode:(BOOL)mobile {
  NSColor* active = [NSColor whiteColor];
  NSColor* inactive = [NSColor colorWithWhite:1.0 alpha:0.35];
  _desktopButton.contentTintColor = mobile ? inactive : active;
  _mobileButton.contentTintColor = mobile ? active : inactive;
  _desktopButton.selectedState = !mobile;
  _mobileButton.selectedState = mobile;
}

#pragma mark - NSTextFieldDelegate

- (void)addressFieldDidFocus {
  // Show the full URL for editing and brighten the host pill while focused.
  if (_fullURL.length > 0) {
    _addressField.stringValue = _fullURL;
  }
  _addressField.superview.layer.borderColor =
      [NSColor colorWithWhite:1.0 alpha:0.30].CGColor;
  dispatch_async(dispatch_get_main_queue(), ^{
    NSTextView* editor = (NSTextView*)[self.addressField currentEditor];
    if ([editor isKindOfClass:[NSTextView class]]) {
      editor.insertionPointColor = [NSColor whiteColor];
      editor.drawsBackground = NO;
      [editor selectAll:nil];
    }
  });
}

- (void)controlTextDidEndEditing:(NSNotification*)notification {
  NSTextField* textField = notification.object;
  if (textField == _addressField) {
    NSNumber* reason = notification.userInfo[@"NSTextMovement"];
    if (reason && reason.integerValue == NSReturnTextMovement) {
      [self navigateToURL:_addressField.stringValue];
      dispatch_async(dispatch_get_main_queue(), ^{
        [self.window makeFirstResponder:nil];
      });
    }
    _addressField.superview.layer.borderColor =
        [NSColor colorWithWhite:1.0 alpha:0.15].CGColor;
    [self displayCompactURL];
  }
}

- (void)focusAddressField {
  if (_addressField.superview) {
    [self.window makeFirstResponder:_addressField];
  }
}

#pragma mark - State Updates

- (void)updateNavigationState:(BOOL)canGoBack canGoForward:(BOOL)canGoForward {
  _backButton.enabled = canGoBack;
  _forwardButton.enabled = canGoForward;
}

- (void)updateURL:(NSString*)url {
  self.fullURL = url ?: @"";
  // Don't clobber text the user is currently typing.
  if ([_addressField currentEditor]) {
    return;
  }
  [self displayCompactURL];
}

// Shows just the host (like the mockup); the full URL appears on focus.
- (void)displayCompactURL {
  NSString* host = [NSURL URLWithString:_fullURL].host;
  _addressField.stringValue = host.length > 0 ? host : _fullURL;
}

@end

#pragma mark - BroTabView

@interface BroTabView : NSView
@property (nonatomic, assign) int browserId;
@property (nonatomic, strong) NSImageView* faviconView;
@property (nonatomic, strong) NSProgressIndicator* loadingSpinner;
@property (nonatomic, strong) NSTextField* titleLabel;
@property (nonatomic, strong) NSButton* closeButton;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, copy) NSString* tabURL;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL selectAction;
@property (nonatomic, assign) SEL closeAction;
- (void)setFaviconURL:(NSString*)urlString;
- (void)setLoading:(BOOL)loading;
- (void)setTabURL:(NSString*)url;
- (void)attachAddressField:(NSTextField*)field;
@end

// The tab strip lives INSIDE the toolbar row: each tab is a pill (favicon +
// host + close), the active pill hosts the editable address field, and the
// "+" button trails the last pill. Declared before BroTabView's
// implementation so pills can route arrow-key focus through it.
@interface BroTabBar : NSView
@property (nonatomic, strong) NSMutableArray<BroTabView*>* tabs;
@property (nonatomic, strong) BroHoverButton* addTabButton;
@property (nonatomic, assign) int activeTabId;
- (void)addTabWithBrowserId:(int)browserId title:(NSString*)title;
- (void)removeTabWithBrowserId:(int)browserId;
- (void)setActiveTab:(int)browserId;
- (void)updateTabTitle:(int)browserId title:(NSString*)title;
- (void)updateTabURL:(int)browserId url:(NSString*)url;
- (void)updateTabFavicon:(int)browserId faviconURL:(NSString*)url;
- (void)updateTabLoading:(int)browserId loading:(BOOL)loading;
// Moves keyboard focus to the pill `offset` positions from `tab`.
- (void)focusTabRelativeTo:(BroTabView*)tab offset:(NSInteger)offset;
@end

@implementation BroTabView {
  BOOL hovered_;
  BOOL focused_;
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
    // Keyboard focus shows as a white pill border instead of the system's
    // accent-colored ring.
    self.focusRingType = NSFocusRingTypeNone;

    // Favicon view
    _faviconView = [[NSImageView alloc]
        initWithFrame:NSMakeRect(10, (kTabPillHeight - 15) / 2.0, 15, 15)];
    _faviconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    // Default globe icon
    _faviconView.image = RadixIconImage(RadixIconGlobe, 15);
    _faviconView.contentTintColor = [NSColor secondaryLabelColor];
    [self addSubview:_faviconView];

    // Loading spinner (same position as favicon, hidden by default)
    _loadingSpinner = [[NSProgressIndicator alloc] initWithFrame:_faviconView.frame];
    _loadingSpinner.style = NSProgressIndicatorStyleSpinning;
    _loadingSpinner.controlSize = NSControlSizeSmall;
    _loadingSpinner.hidden = YES;
    [self addSubview:_loadingSpinner];

    // Host label (hidden on the active pill, where the address field shows)
    _titleLabel = [[NSTextField alloc]
        initWithFrame:NSMakeRect(32, (kTabPillHeight - 18) / 2.0,
                                 frame.size.width - 32 - 26, 18)];
    _titleLabel.stringValue = @"";
    _titleLabel.font = [NSFont systemFontOfSize:12.0];
    _titleLabel.textColor = [NSColor secondaryLabelColor];
    _titleLabel.bordered = NO;
    _titleLabel.editable = NO;
    _titleLabel.selectable = NO;
    _titleLabel.drawsBackground = NO;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.cell.truncatesLastVisibleLine = YES;
    _titleLabel.autoresizingMask = NSViewWidthSizable;
    [self addSubview:_titleLabel];

    // Close button (always visible, like the mockup)
    BroHoverButton* closeButton = [[BroHoverButton alloc]
        initWithFrame:NSMakeRect(frame.size.width - 26,
                                 (kTabPillHeight - 16) / 2.0, 16, 16)];
    closeButton.bezelStyle = NSBezelStyleTexturedRounded;
    closeButton.bordered = NO;
    closeButton.title = @"";
    closeButton.image = RadixIconImage(RadixIconCross2, 10);
    closeButton.imagePosition = NSImageOnly;
    closeButton.contentTintColor = [NSColor tertiaryLabelColor];
    closeButton.layer.cornerRadius = 4.0;
    closeButton.target = self;
    closeButton.action = @selector(handleClose:);
    closeButton.autoresizingMask = NSViewMinXMargin;
    closeButton.accessibilityLabel = @"Close tab";
    closeButton.toolTip = @"Close tab";
    _closeButton = closeButton;
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

  NSURL* url = [NSURL URLWithString:urlString];
  if (!url) return;

  // Load favicon asynchronously
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSImage* image = [[NSImage alloc] initWithContentsOfURL:url];
    if (image) {
      dispatch_async(dispatch_get_main_queue(), ^{
        self.faviconView.image = image;
        self.faviconView.contentTintColor = nil;
      });
    }
  });
}

- (void)setTabURL:(NSString*)url {
  _tabURL = [url copy] ?: @"";
  NSString* host = [NSURL URLWithString:_tabURL].host;
  _titleLabel.stringValue = host.length > 0 ? host : _tabURL;
}

// Hosts the toolbar's shared address field (this pill is the active tab).
- (void)attachAddressField:(NSTextField*)field {
  NSRect bounds = self.bounds;
  field.frame = NSMakeRect(32, (bounds.size.height - 18) / 2.0,
                           bounds.size.width - 32 - 26, 18);
  field.autoresizingMask = NSViewWidthSizable;
  [self addSubview:field];
  _titleLabel.hidden = YES;
}

- (void)setLoading:(BOOL)loading {
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

// Selected (active) pills are brightest; hovered inactive pills sit between
// the selected and resting looks. Keyboard focus overrides the border with a
// solid white ring.
- (void)updateAppearance {
  if (_isActive) {
    self.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.08].CGColor;
    self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.15].CGColor;
    _titleLabel.textColor = [NSColor labelColor];
  } else {
    CGFloat bg = hovered_ ? 0.06 : 0.03;
    CGFloat border = hovered_ ? 0.12 : 0.08;
    self.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:bg].CGColor;
    self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:border].CGColor;
    _titleLabel.textColor = [NSColor secondaryLabelColor];
    _titleLabel.hidden = NO;  // the address field only lives in the active pill
  }
  if (focused_) {
    self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.9].CGColor;
    self.layer.borderWidth = 2.0;
  } else {
    self.layer.borderWidth = 1.0;
  }
}

- (void)setIsActive:(BOOL)isActive {
  _isActive = isActive;
  [self updateAppearance];
}

- (void)performSelect {
  if (_target && _selectAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [_target performSelector:_selectAction withObject:self];
#pragma clang diagnostic pop
  }
}

- (void)mouseDown:(NSEvent*)event {
  [self performSelect];
}

- (void)mouseEntered:(NSEvent*)event {
  hovered_ = YES;
  [self updateAppearance];
}

- (void)mouseExited:(NSEvent*)event {
  hovered_ = NO;
  [self updateAppearance];
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
  NSString* host = _titleLabel.stringValue;
  if (host.length > 0) {
    return host;
  }
  return self.toolTip.length > 0 ? self.toolTip : @"New Tab";
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

#pragma mark - BroTabBar

@implementation BroTabBar

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _tabs = [NSMutableArray array];
    _activeTabId = -1;
    self.autoresizingMask = NSViewWidthSizable;

    // Performance: Enable layer-backing for GPU compositing
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

    // Bordered rounded-rect "+" button, repositioned after the last pill.
    CGFloat pillY = (frame.size.height - kTabPillHeight) / 2.0;
    _addTabButton = [[BroHoverButton alloc]
        initWithFrame:NSMakeRect(0, pillY, kTabPillHeight, kTabPillHeight)];
    _addTabButton.bordered = NO;
    _addTabButton.title = @"";
    _addTabButton.image = RadixIconImage(RadixIconPlus, 15);
    _addTabButton.imagePosition = NSImageOnly;
    _addTabButton.contentTintColor = [NSColor colorWithWhite:1.0 alpha:0.85];
    _addTabButton.layer.cornerRadius = 8.0;
    _addTabButton.layer.borderWidth = 1.0;
    _addTabButton.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.15].CGColor;
    _addTabButton.target = self;
    _addTabButton.action = @selector(createNewTab:);
    _addTabButton.accessibilityLabel = @"New tab";
    _addTabButton.toolTip = @"New tab";
    [self addSubview:_addTabButton];
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

- (void)addTabWithBrowserId:(int)browserId title:(NSString*)title {
  CGFloat pillY = (self.frame.size.height - kTabPillHeight) / 2.0;
  BroTabView* tab = [[BroTabView alloc]
      initWithFrame:NSMakeRect(0, pillY, kTabPillMaxWidth, kTabPillHeight)
          browserId:browserId];
  tab.toolTip = title ?: @"New Tab";
  tab.target = self;
  tab.selectAction = @selector(tabSelected:);
  tab.closeAction = @selector(tabClosed:);
  [_tabs addObject:tab];
  [self addSubview:tab];

  [self layoutTabs];
  [self.window recalculateKeyViewLoop];
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

- (void)removeTabWithBrowserId:(int)browserId {
  BroTabView* tabToRemove = nil;
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      tabToRemove = tab;
      break;
    }
  }

  if (tabToRemove) {
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
    [tabToRemove removeFromSuperview];
    [_tabs removeObject:tabToRemove];
    [self layoutTabs];
    [self.window recalculateKeyViewLoop];
  }
}

- (void)setActiveTab:(int)browserId {
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
    [g_toolbar.addressField removeFromSuperview];
    if (activeTab) {
      [activeTab attachAddressField:g_toolbar.addressField];
    }
    // The viewport toggles reflect the active tab's own emulation state.
    [g_toolbar setViewportMode:TabIsMobile(browserId)];
  }
}

- (void)updateTabTitle:(int)browserId title:(NSString*)title {
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      // Pills display the host; the page title becomes a tooltip.
      tab.toolTip = title ?: @"New Tab";
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

- (void)layoutTabs {
  CGFloat pillY = (self.frame.size.height - kTabPillHeight) / 2.0;

  // Fit pills to the available strip width (minus the "+" button), between
  // a floor and the mockup's pill width.
  CGFloat availableWidth = self.frame.size.width - (kTabPillHeight + 8.0);
  NSUInteger count = MAX(_tabs.count, (NSUInteger)1);
  CGFloat fitWidth = availableWidth / count - 8.0;
  CGFloat tabWidth = MIN(MAX(fitWidth, kTabPillMinWidth), kTabPillMaxWidth);

  CGFloat x = 0.0;
  for (BroTabView* tab in _tabs) {
    tab.frame = NSMakeRect(x, pillY, tabWidth, kTabPillHeight);
    x += tabWidth + 8.0;
  }

  _addTabButton.frame = NSMakeRect(x, pillY, kTabPillHeight, kTabPillHeight);
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  [self layoutTabs];
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

@end

#pragma mark - BroWindow

@interface BroWindow : NSWindow
@property (nonatomic, strong) NSView* browserContainer;
@property (nonatomic, strong) BroToolbar* navToolbar;
@property (nonatomic, strong) BroTabBar* tabBar;
@end

@implementation BroWindow

- (instancetype)init {
  NSRect frame = NSMakeRect(0, 0, 1200, 800);
  self = [super initWithContentRect:frame
                          styleMask:NSWindowStyleMaskTitled |
                                    NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskMiniaturizable |
                                    NSWindowStyleMaskResizable |
                                    NSWindowStyleMaskFullSizeContentView
                            backing:NSBackingStoreBuffered
                              defer:NO];
  if (self) {
    // Glassy near-black chrome: a behind-window blur tinted dark, so the
    // desktop shows through the chrome as frosted glass. The transparent
    // titlebar keeps the traffic lights floating inline with the toolbar row.
    self.titlebarAppearsTransparent = YES;
    self.titleVisibility = NSWindowTitleHidden;
    self.backgroundColor = [NSColor clearColor];
    self.opaque = NO;

    // An empty unified toolbar grows the titlebar to the chrome row's height,
    // which vertically centers the traffic lights on the same midline as the
    // nav buttons and pills.
    NSToolbar* titlebarSpacer = [[NSToolbar alloc] initWithIdentifier:@"BroTitlebarSpacer"];
    titlebarSpacer.showsBaselineSeparator = NO;
    self.toolbar = titlebarSpacer;
    self.toolbarStyle = NSWindowToolbarStyleUnified;

    NSVisualEffectView* content = [[NSVisualEffectView alloc] initWithFrame:frame];
    content.material = NSVisualEffectMaterialHUDWindow;
    content.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    content.state = NSVisualEffectStateFollowsWindowActiveState;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.contentView = content;

    // Dark tint over the blur to stay close to the mockup's near-black.
    NSView* tint = [[NSView alloc] initWithFrame:frame];
    tint.wantsLayer = YES;
    tint.layer.backgroundColor =
        [[NSColor blackColor] colorWithAlphaComponent:0.35].CGColor;
    tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:tint];

    // Single chrome row at the very top; its content is inset past the
    // traffic lights.
    CGFloat toolbarY = frame.size.height - kToolbarHeight;
    _navToolbar = [[BroToolbar alloc] initWithFrame:NSMakeRect(0, toolbarY, frame.size.width, kToolbarHeight)];
    [content addSubview:_navToolbar];
    g_toolbar = _navToolbar;

    // Tab strip inline in the toolbar row: after the nav buttons, before the
    // right-aligned viewport toggles.
    CGFloat stripX = kTrafficLightInset + 3 * (kButtonSize + kButtonSpacing) + 8.0;
    CGFloat stripRight = frame.size.width - 12.0 - kButtonSize - kButtonSpacing -
                         kButtonSize - 16.0;
    _tabBar = [[BroTabBar alloc]
        initWithFrame:NSMakeRect(stripX, 0, stripRight - stripX, kToolbarHeight)];
    [_navToolbar addSubview:_tabBar];
    g_tab_bar = _tabBar;

    // Create container for browser views (below chrome)
    _browserContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, toolbarY)];
    _browserContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:_browserContainer];

    // Initialize browser views dictionary
    g_browser_views = [NSMutableDictionary dictionary];

    // Keep the Tab-key loop current as pills and buttons come and go.
    self.autorecalculatesKeyViewLoop = YES;

    // Center the window
    [self center];

    // Set minimum size (wide enough for the pill + right-side toggles)
    self.minSize = NSMakeSize(760, 400);
  }
  return self;
}

@end

#pragma mark - CreateNewBrowserTab

// Frames a per-tab container for that tab's viewport mode: full-bleed on
// desktop, a centered 390pt column in mobile mode.
static void ApplyViewportFrameToContainer(NSView* container, BOOL mobile) {
  NSRect bounds = g_main_window.browserContainer.bounds;
  if (mobile) {
    CGFloat width = MIN(kMobileViewportWidth, bounds.size.width);
    container.frame = NSMakeRect((bounds.size.width - width) / 2.0, 0, width,
                                 bounds.size.height);
    container.autoresizingMask =
        NSViewMinXMargin | NSViewMaxXMargin | NSViewHeightSizable;
  } else {
    container.frame = bounds;
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
}

// Creates a hidden per-tab container view inside the main browser area.
// The browser created into it is adopted as a tab in OnTabCreated, which
// finds the container as the superview of the browser's native view.
// New tabs always start in desktop mode.
static NSView* CreateTabContainerView(void) {
  if (!g_main_window || !g_main_window.browserContainer) {
    return nil;
  }
  NSView* browserContainer = [[NSView alloc] init];
  ApplyViewportFrameToContainer(browserContainer, NO);
  browserContainer.hidden = YES;  // Will be shown when tab is activated
  [g_main_window.browserContainer addSubview:browserContainer];
  return browserContainer;
}

static void UpdateChromeLayout(void) {
  if (!g_main_window || !g_main_window.browserContainer) {
    return;
  }
  for (NSNumber* key in g_browser_views) {
    ApplyViewportFrameToContainer(g_browser_views[key],
                                  TabIsMobile(key.intValue));
  }
}

// Chrome's preset zoom stops. CEF zoom levels are logarithmic:
// scale = 1.2^level, so level = log(scale) / log(1.2).
static const double kZoomPercents[] = {25,  33,  50,  67,  75,  80,
                                       90,  100, 110, 125, 150, 175,
                                       200, 250, 300, 400, 500};
static const int kZoomPercentCount =
    sizeof(kZoomPercents) / sizeof(kZoomPercents[0]);

static double ZoomLevelToPercent(double level) {
  return pow(1.2, level) * 100.0;
}

static double PercentToZoomLevel(double percent) {
  return log(percent / 100.0) / log(1.2);
}

// Next ladder stop above/below |currentPercent|. The 0.5 slack absorbs
// floating-point drift from the level<->percent round trip.
static double NextZoomPercent(double currentPercent, BOOL zoomingIn) {
  if (zoomingIn) {
    for (int i = 0; i < kZoomPercentCount; ++i) {
      if (kZoomPercents[i] > currentPercent + 0.5) {
        return kZoomPercents[i];
      }
    }
    return kZoomPercents[kZoomPercentCount - 1];
  }
  for (int i = kZoomPercentCount - 1; i >= 0; --i) {
    if (kZoomPercents[i] < currentPercent - 0.5) {
      return kZoomPercents[i];
    }
  }
  return kZoomPercents[0];
}

// Transient bubble showing the current zoom percentage.
static NSView* g_zoom_hud = nil;
static NSTextField* g_zoom_hud_label = nil;
static NSTimer* g_zoom_hud_timer = nil;

static void ShowZoomHUD(int percent) {
  if (!g_main_window || !g_main_window.browserContainer) {
    return;
  }
  NSView* container = g_main_window.browserContainer;

  if (!g_zoom_hud) {
    g_zoom_hud = [[NSView alloc] initWithFrame:NSZeroRect];
    g_zoom_hud.wantsLayer = YES;
    g_zoom_hud.layer.cornerRadius = 8.0;
    g_zoom_hud.layer.backgroundColor =
        [NSColor colorWithWhite:0.15 alpha:0.92].CGColor;

    g_zoom_hud_label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    g_zoom_hud_label.editable = NO;
    g_zoom_hud_label.selectable = NO;
    g_zoom_hud_label.bezeled = NO;
    g_zoom_hud_label.bordered = NO;
    g_zoom_hud_label.drawsBackground = NO;
    g_zoom_hud_label.font = [NSFont boldSystemFontOfSize:14.0];
    g_zoom_hud_label.textColor = [NSColor whiteColor];
    g_zoom_hud_label.alignment = NSTextAlignmentCenter;
    [g_zoom_hud addSubview:g_zoom_hud_label];
  }
  // (Re-)add last so the HUD composites above the native CEF browser view.
  if (g_zoom_hud.superview != container) {
    [g_zoom_hud removeFromSuperview];
    [container addSubview:g_zoom_hud];
  }

  g_zoom_hud_label.stringValue = [NSString stringWithFormat:@"%d%%", percent];
  [g_zoom_hud_label sizeToFit];
  NSSize labelSize = g_zoom_hud_label.frame.size;
  const CGFloat padX = 14.0;
  const CGFloat padY = 8.0;
  NSSize hudSize =
      NSMakeSize(labelSize.width + padX * 2, labelSize.height + padY * 2);
  NSRect bounds = container.bounds;
  g_zoom_hud.frame = NSMakeRect(NSMaxX(bounds) - hudSize.width - 16.0,
                                NSMaxY(bounds) - hudSize.height - 16.0,
                                hudSize.width, hudSize.height);
  g_zoom_hud_label.frame =
      NSMakeRect(padX, padY, labelSize.width, labelSize.height);

  g_zoom_hud.hidden = NO;
  g_zoom_hud.alphaValue = 1.0;

  [g_zoom_hud_timer invalidate];
  g_zoom_hud_timer =
      [NSTimer scheduledTimerWithTimeInterval:1.2
                                      repeats:NO
                                        block:^(NSTimer* timer) {
        g_zoom_hud_timer = nil;
        [NSAnimationContext
            runAnimationGroup:^(NSAnimationContext* ctx) {
              ctx.duration = 0.25;
              g_zoom_hud.animator.alphaValue = 0.0;
            }
            completionHandler:^{
              // Skip hiding if another press restarted the HUD mid-fade.
              if (!g_zoom_hud_timer) {
                g_zoom_hud.hidden = YES;
              }
            }];
      }];
}

static void CreateNewBrowserTabWithURL(const std::string& url) {
  BroHandler* handler = BroHandler::GetInstance();
  if (!handler) {
    return;
  }

  NSView* browserContainer = CreateTabContainerView();
  if (!browserContainer) {
    return;
  }

  // Browser settings
  CefBrowserSettings browser_settings;

  // Window info - embed in the new container view
  CefWindowInfo window_info;
  NSRect bounds = browserContainer.bounds;
  window_info.SetAsChild(
      CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(browserContainer),
      CefRect(0, 0, bounds.size.width, bounds.size.height));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  // Create the browser with the specified URL
  CefBrowserHost::CreateBrowser(window_info, handler, url, browser_settings,
                                nullptr, nullptr);
}

static void CreateNewBrowserTab(void) {
  CreateNewBrowserTabWithURL("https://www.google.com");
}

#pragma mark - BroAppDelegate

@interface BroAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
- (void)createApplication:(id)object;
- (void)tryToTerminateApplication:(NSApplication*)app;
- (void)createBrowserInWindow;
@end

// Provide the CefAppProtocol implementation required by CEF.
@interface BroApplication : NSApplication <CefAppProtocol> {
 @private
  BOOL handlingSendEvent_;
}
@end

@implementation BroApplication

- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

- (void)terminate:(id)sender {
  BroAppDelegate* delegate = static_cast<BroAppDelegate*>([NSApp delegate]);
  [delegate tryToTerminateApplication:self];
}

@end

@implementation BroAppDelegate

- (void)createApplication:(id)object {
  // The chrome is designed dark-only; force dark so system controls match.
  NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

  // Create the main menu
  [self setupMainMenu];

  // Create the main window
  g_main_window = [[BroWindow alloc] init];
  g_main_window.delegate = self;
  g_main_window.title = @"Bro";

  // Show the window
  [g_main_window makeKeyAndOrderFront:nil];

  // Create the CEF browser in our window
  [self performSelectorOnMainThread:@selector(createBrowserInWindow)
                         withObject:nil
                      waitUntilDone:NO];
}

- (void)setupMainMenu {
  NSMenu* mainMenu = [[NSMenu alloc] init];

  // App menu
  NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
  NSMenu* appMenu = [[NSMenu alloc] init];

  [appMenu addItemWithTitle:@"About Bro"
                     action:@selector(orderFrontStandardAboutPanel:)
              keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit Bro"
                     action:@selector(terminate:)
              keyEquivalent:@"q"];

  appMenuItem.submenu = appMenu;
  [mainMenu addItem:appMenuItem];

  // Edit menu (for copy/paste in browser)
  NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
  NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

  [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
  [editMenu addItem:[NSMenuItem separatorItem]];
  [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

  editMenuItem.submenu = editMenu;
  [mainMenu addItem:editMenuItem];

  // View menu with navigation shortcuts
  NSMenuItem* viewMenuItem = [[NSMenuItem alloc] init];
  NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];

  [viewMenu addItemWithTitle:@"Reload" action:@selector(reloadPage:) keyEquivalent:@"r"];
  NSMenuItem* hardReloadItem = [viewMenu addItemWithTitle:@"Hard Reload"
                                                   action:@selector(hardReload:)
                                            keyEquivalent:@"r"];
  hardReloadItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [viewMenu addItemWithTitle:@"Stop" action:@selector(stopLoading:) keyEquivalent:@"."];
  [viewMenu addItem:[NSMenuItem separatorItem]];

  // Zoom controls. Cmd+"=" is the unshifted "+" key; a "+" key equivalent
  // with a Command-only mask would never match because typing "+" requires
  // Shift, which AppKit only auto-infers for uppercase letters.
  [viewMenu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"="];
  NSMenuItem* zoomInShifted = [[NSMenuItem alloc] initWithTitle:@"Zoom In"
                                                         action:@selector(zoomIn:)
                                                  keyEquivalent:@"+"];
  zoomInShifted.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  zoomInShifted.hidden = YES;
  [viewMenu addItem:zoomInShifted];
  [viewMenu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@"-"];
  [viewMenu addItemWithTitle:@"Actual Size" action:@selector(zoomReset:) keyEquivalent:@"0"];
  [viewMenu addItem:[NSMenuItem separatorItem]];

  // DevTools (Cmd+Option+I)
  NSMenuItem* devToolsItem = [viewMenu addItemWithTitle:@"Developer Tools"
                                                 action:@selector(toggleDevTools:)
                                          keyEquivalent:@"i"];
  devToolsItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;

  // DevTools alternative (F12) - use special function key
  NSMenuItem* devToolsF12 = [[NSMenuItem alloc] initWithTitle:@"Developer Tools (F12)"
                                                       action:@selector(toggleDevTools:)
                                                keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSF12FunctionKey]];
  devToolsF12.keyEquivalentModifierMask = 0;
  devToolsF12.hidden = YES;  // Hide from menu but still active
  [viewMenu addItem:devToolsF12];

  [viewMenu addItem:[NSMenuItem separatorItem]];
  [viewMenu addItemWithTitle:@"WebAssembly Benchmark"
                      action:@selector(openWasmBenchmark:)
               keyEquivalent:@""];

  viewMenuItem.submenu = viewMenu;
  [mainMenu addItem:viewMenuItem];

  // History menu
  NSMenuItem* historyMenuItem = [[NSMenuItem alloc] init];
  NSMenu* historyMenu = [[NSMenu alloc] initWithTitle:@"History"];

  NSMenuItem* backItem = [historyMenu addItemWithTitle:@"Back" action:@selector(goBack:) keyEquivalent:@"["];
  backItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;

  NSMenuItem* forwardItem = [historyMenu addItemWithTitle:@"Forward" action:@selector(goForward:) keyEquivalent:@"]"];
  forwardItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;

  historyMenuItem.submenu = historyMenu;
  [mainMenu addItem:historyMenuItem];

  // File menu (for tab operations)
  NSMenuItem* fileMenuItem = [[NSMenuItem alloc] init];
  NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

  [fileMenu addItemWithTitle:@"New Tab"
                      action:@selector(newTab:)
               keyEquivalent:@"t"];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  [fileMenu addItemWithTitle:@"Close Tab"
                      action:@selector(closeTab:)
               keyEquivalent:@"w"];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  [fileMenu addItemWithTitle:@"Open Location..."
                      action:@selector(focusAddressBar:)
               keyEquivalent:@"l"];

  fileMenuItem.submenu = fileMenu;
  [mainMenu addItem:fileMenuItem];

  // Window menu
  NSMenuItem* windowMenuItem = [[NSMenuItem alloc] init];
  NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

  [windowMenu addItemWithTitle:@"Minimize"
                        action:@selector(performMiniaturize:)
                 keyEquivalent:@"m"];
  [windowMenu addItemWithTitle:@"Zoom"
                        action:@selector(performZoom:)
                 keyEquivalent:@""];

  windowMenuItem.submenu = windowMenu;
  [mainMenu addItem:windowMenuItem];

  [NSApp setMainMenu:mainMenu];
  [NSApp setWindowsMenu:windowMenu];
}

- (void)createBrowserInWindow {
  if (!g_main_window || !g_main_window.browserContainer) {
    return;
  }

  // Create the handler (shared across all browsers)
  CefRefPtr<BroHandler> handler(new BroHandler(true));

  NSView* browserContainer = CreateTabContainerView();
  if (!browserContainer) {
    return;
  }

  // Browser settings
  CefBrowserSettings browser_settings;

  // Window info - embed in the container view
  CefWindowInfo window_info;
  NSRect bounds = browserContainer.bounds;
  window_info.SetAsChild(
      CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(browserContainer),
      CefRect(0, 0, bounds.size.width, bounds.size.height));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  // Create the browser
  std::string url = "https://www.google.com";
  CefBrowserHost::CreateBrowser(window_info, handler, url, browser_settings,
                                nullptr, nullptr);

  // Update address bar
  if (g_toolbar) {
    [g_toolbar updateURL:@"https://www.google.com"];
  }
}

- (void)tryToTerminateApplication:(NSApplication*)app {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler && !handler->IsClosing()) {
    handler->CloseAllBrowsers(false);
  }
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  return NSTerminateNow;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)theApplication
                    hasVisibleWindows:(BOOL)flag {
  if (!flag && g_main_window) {
    if (g_main_window.miniaturized) {
      [g_main_window deminiaturize:nil];
    }
    [g_main_window makeKeyAndOrderFront:nil];
  }
  return NO;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app {
  return YES;
}

// Menu actions
- (void)goBack:(id)sender {
  if (g_toolbar) {
    [g_toolbar goBack:sender];
  }
}

- (void)goForward:(id)sender {
  if (g_toolbar) {
    [g_toolbar goForward:sender];
  }
}

- (void)reloadPage:(id)sender {
  if (g_toolbar) {
    [g_toolbar refresh:sender];
  }
}

- (void)hardReload:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      browser->ReloadIgnoreCache();
    }
  }
}

- (void)stopLoading:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      browser->StopLoad();
    }
  }
}

- (void)newTab:(id)sender {
  CreateNewBrowserTab();
}

- (void)closeTab:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    int activeId = handler->GetActiveBrowserId();
    if (g_tab_bar && g_tab_bar.tabs.count > 1) {
      handler->CloseBrowser(activeId);
    } else if (g_main_window) {
      // Closing the last tab closes the window (and quits, like a browser).
      [g_main_window performClose:sender];
    }
  }
}

- (void)openWasmBenchmark:(id)sender {
  NSString* path = [[NSBundle mainBundle] pathForResource:@"wasm-bench"
                                                   ofType:@"html"];
  if (path) {
    NSURL* url = [NSURL fileURLWithPath:path];
    CreateNewBrowserTabWithURL([[url absoluteString] UTF8String]);
  }
}

- (void)focusAddressBar:(id)sender {
  if (g_toolbar) {
    [g_toolbar focusAddressField];
  }
}

- (void)stepZoom:(BOOL)zoomingIn {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      double currentPercent =
          ZoomLevelToPercent(browser->GetHost()->GetZoomLevel());
      double targetPercent = NextZoomPercent(currentPercent, zoomingIn);
      browser->GetHost()->SetZoomLevel(PercentToZoomLevel(targetPercent));
      ShowZoomHUD((int)lround(targetPercent));
    }
  }
}

- (void)zoomIn:(id)sender {
  [self stepZoom:YES];
}

- (void)zoomOut:(id)sender {
  [self stepZoom:NO];
}

- (void)zoomReset:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      browser->GetHost()->SetZoomLevel(0.0);
      ShowZoomHUD(100);
    }
  }
}

- (void)toggleDevTools:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      if (browser->GetHost()->HasDevTools()) {
        browser->GetHost()->CloseDevTools();
      } else {
        CefWindowInfo windowInfo;
        CefBrowserSettings settings;
        browser->GetHost()->ShowDevTools(windowInfo, nullptr, settings, CefPoint());
      }
    }
  }
}

// NSWindowDelegate
- (BOOL)windowShouldClose:(NSWindow*)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler && !handler->IsClosing()) {
    handler->CloseAllBrowsers(false);
    return NO;  // Don't close yet, wait for browsers to close
  }
  return YES;
}

- (void)windowWillClose:(NSNotification*)notification {
  g_main_window = nil;
  g_toolbar = nil;
  g_tab_bar = nil;
  [g_browser_views removeAllObjects];
}

@end

#pragma mark - Callback Functions for Handler

// These functions are called from BroHandler to update the UI
void UpdateNavigationState(bool canGoBack, bool canGoForward) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_toolbar) {
      [g_toolbar updateNavigationState:canGoBack canGoForward:canGoForward];
    }
  });
}

void UpdateURL(const std::string& url) {
  // Convert before dispatching: the block would otherwise capture the
  // std::string parameter by reference, which dangles once the caller
  // returns (use-after-free; crashed with garbage/NULL c_str()).
  NSString* urlStr = [NSString stringWithUTF8String:url.c_str()] ?: @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_toolbar) {
      [g_toolbar updateURL:urlStr];
    }
  });
}

void SetLoading(bool loading) {
  // Loading state is shown per-tab (each pill swaps its favicon for a
  // spinner via OnTabLoadingChanged); nothing extra to do for the active tab.
  (void)loading;
}

bool OnTabCreated(int browser_id, const std::string& url, void* native_view) {
  // Called on the CEF UI thread, which is the main thread here, so AppKit
  // access and synchronous adoption are safe (a deferred handoff through a
  // shared "pending container" global raced when two tabs were created
  // quickly).
  NSView* cefView = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(
      static_cast<CefWindowHandle>(native_view));
  NSView* container = cefView.superview;

  // Only adopt browsers whose view was created inside a per-tab container in
  // the main window. Anything else (e.g. DevTools) gets no tab and must not
  // touch tab state.
  if (!container || !g_main_window ||
      container == g_main_window.browserContainer ||
      ![container isDescendantOf:g_main_window.browserContainer]) {
    return false;
  }

  g_browser_views[@(browser_id)] = container;

  // If this was a popup's container, it is no longer pending.
  for (NSNumber* popupId in [g_pending_popup_containers allKeysForObject:container]) {
    [g_pending_popup_containers removeObjectForKey:popupId];
  }

  // Add tab to tab bar
  if (g_tab_bar) {
    [g_tab_bar addTabWithBrowserId:browser_id title:@"New Tab"];
    NSString* urlStr = [NSString stringWithUTF8String:url.c_str()] ?: @"";
    [g_tab_bar updateTabURL:browser_id url:urlStr];
    [g_tab_bar setActiveTab:browser_id];
  }

  // Show this browser's container, hide others
  for (NSNumber* key in g_browser_views) {
    NSView* view = g_browser_views[key];
    view.hidden = (key.intValue != browser_id);
  }
  return true;
}

bool HasTabView(int browser_id) {
  return g_browser_views[@(browser_id)] != nil;
}

void DetachTabView(int browser_id) {
  // Deferred so the view teardown (which destroys the CEF browser) doesn't
  // re-enter CEF from inside DoClose.
  dispatch_async(dispatch_get_main_queue(), ^{
    NSView* containerView = g_browser_views[@(browser_id)];
    if (containerView) {
      [containerView removeFromSuperview];
      [g_browser_views removeObjectForKey:@(browser_id)];
    }
  });
}

void* CreatePopupTabContainer(int popup_id, int* width, int* height) {
  NSView* container = CreateTabContainerView();
  if (!container) {
    return nullptr;
  }
  if (!g_pending_popup_containers) {
    g_pending_popup_containers = [NSMutableDictionary dictionary];
  }
  g_pending_popup_containers[@(popup_id)] = container;
  NSRect bounds = container.bounds;
  *width = (int)bounds.size.width;
  *height = (int)bounds.size.height;
  return CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(container);
}

void RemovePopupTabContainer(int popup_id) {
  NSView* container = g_pending_popup_containers[@(popup_id)];
  if (container) {
    [container removeFromSuperview];
    [g_pending_popup_containers removeObjectForKey:@(popup_id)];
  }
}

void OnTabTitleChanged(int browser_id, const std::string& title) {
  // Convert before dispatching (see UpdateURL).
  NSString* titleStr = [NSString stringWithUTF8String:title.c_str()] ?: @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_tab_bar) {
      [g_tab_bar updateTabTitle:browser_id title:titleStr];
    }
  });
}

void OnTabURLChanged(int browser_id, const std::string& url) {
  // Convert before dispatching (see UpdateURL).
  NSString* urlStr = [NSString stringWithUTF8String:url.c_str()] ?: @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_tab_bar) {
      [g_tab_bar updateTabURL:browser_id url:urlStr];
    }
  });
}

void OnTabFaviconChanged(int browser_id, const std::string& favicon_url) {
  // Convert before dispatching (see UpdateURL).
  NSString* urlStr = [NSString stringWithUTF8String:favicon_url.c_str()] ?: @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_tab_bar) {
      [g_tab_bar updateTabFavicon:browser_id faviconURL:urlStr];
    }
  });
}

void OnTabLoadingChanged(int browser_id, bool is_loading) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_tab_bar) {
      [g_tab_bar updateTabLoading:browser_id loading:is_loading];
    }
  });
}

void OnTabClosed(int browser_id) {
  dispatch_async(dispatch_get_main_queue(), ^{
    // Remove from tab bar
    if (g_tab_bar) {
      [g_tab_bar removeTabWithBrowserId:browser_id];
    }

    // Remove and destroy the container view
    NSView* containerView = g_browser_views[@(browser_id)];
    if (containerView) {
      [containerView removeFromSuperview];
      [g_browser_views removeObjectForKey:@(browser_id)];
    }
  });
}

void OnActiveTabChanged(int browser_id) {
  dispatch_async(dispatch_get_main_queue(), ^{
    // Update tab bar
    if (g_tab_bar) {
      [g_tab_bar setActiveTab:browser_id];
    }

    // Show this browser's container, hide others
    for (NSNumber* key in g_browser_views) {
      NSView* view = g_browser_views[key];
      view.hidden = (key.intValue != browser_id);
    }
  });
}

void OpenLinkInNewTab(const std::string& url) {
  // Copy before dispatching (see UpdateURL): the block must own the string.
  std::string url_copy = url;
  dispatch_async(dispatch_get_main_queue(), ^{
    CreateNewBrowserTabWithURL(url_copy);
  });
}

#pragma mark - Main

// Entry point function for the browser process.
int main(int argc, char* argv[]) {
  // Load the CEF framework library at runtime instead of linking directly
  // as required by the macOS sandbox implementation.
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) {
    return 1;
  }

  // Provide CEF with command-line arguments.
  CefMainArgs main_args(argc, argv);

  @autoreleasepool {
    // Initialize the BroApplication instance.
    [BroApplication sharedApplication];

    CHECK([NSApp isKindOfClass:[BroApplication class]]);

    // Specify CEF global settings here.
    CefSettings settings;

#if !defined(CEF_USE_SANDBOX)
    settings.no_sandbox = true;
#endif

    // Remote debugging gives any local process full control of the browser,
    // so never enable it unconditionally: Debug builds listen on 9222,
    // Release builds only when BRO_REMOTE_DEBUG_PORT is set.
#ifndef NDEBUG
    settings.remote_debugging_port = 9222;
#else
    if (const char* debug_port = getenv("BRO_REMOTE_DEBUG_PORT")) {
      int port = atoi(debug_port);
      if (port > 1024 && port < 65536) {
        settings.remote_debugging_port = port;
      }
    }
#endif

    // Persistent cache in Application Support (the temp directory is purged
    // by the OS, which silently discarded the HTTP cache and the V8/WASM
    // compiled-code caches between launches).
    NSString* appSupport = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString* cachePath = [appSupport stringByAppendingPathComponent:@"Bro"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cachePath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    CefString(&settings.root_cache_path).FromString([cachePath UTF8String]);
    CefString(&settings.cache_path).FromString([cachePath UTF8String]);

    // Reduce logging in Release builds
#ifdef NDEBUG
    settings.log_severity = LOGSEVERITY_WARNING;
#else
    settings.log_severity = LOGSEVERITY_INFO;
#endif

    // Performance: Persist session cookies for faster repeat visits
    settings.persist_session_cookies = true;

    // Performance: Set background color to reduce flash-of-white
    settings.background_color = CefColorSetARGB(255, 30, 30, 30);

    // BroApp implements application-level callbacks for the browser process.
    CefRefPtr<BroApp> app(new BroApp);

    // Initialize the CEF browser process.
    if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
      return CefGetExitCode();
    }

    // Create the application delegate.
    BroAppDelegate* delegate = [[BroAppDelegate alloc] init];
    NSApp.delegate = delegate;

    [delegate performSelectorOnMainThread:@selector(createApplication:)
                               withObject:nil
                            waitUntilDone:NO];

    // Run the CEF message loop.
    CefRunMessageLoop();

    // Shut down CEF.
    CefShutdown();

#if !__has_feature(objc_arc)
    [delegate release];
#endif
    delegate = nil;
  }

  return 0;
}
