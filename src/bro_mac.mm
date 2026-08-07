// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

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
// Wide enough that the "Enter URL or search" placeholder reads in full.
static const CGFloat kTabPillMaxWidth = 180.0;
static const CGFloat kTabPillMinWidth = 110.0;
// In narrow windows (mobile shell) pills may shrink below the comfortable
// minimum rather than overlap the controls to the right of the strip.
// Below kTabPillTextMinWidth there is no room for readable text beside the
// favicon, so pills collapse to squares — favicon only, as wide as they are
// tall — and the active pill alone opens back up so its URL stays typable.
static const CGFloat kTabPillTextMinWidth = 64.0;
// Pills narrower than this drop their close button so it doesn't crowd the
// favicon and title.
static const CGFloat kTabPillCloseMinWidth = 80.0;
static const CGFloat kTabPillHeight = 28.0;
// A collapsed pill is exactly square.
static const CGFloat kTabPillSquareWidth = kTabPillHeight;
// The "+" button is half the pill's size, centered on the same midline.
static const CGFloat kAddTabButtonSize = kTabPillHeight / 2.0;
static const CGFloat kPillCornerRadius = 8.0;
static const CGFloat kTrafficLightInset = 100.0;
static const CGFloat kMobileViewportWidth = 390.0;
static const CGFloat kMobileViewportHeight = 844.0;  // matches CDP metrics
// Shell width while the window hugs the mobile viewport: the 390pt column
// plus bezels wide enough that the chrome row (~460pt minimum) still fits.
static const CGFloat kMobileShellWidth = 480.0;
static const NSTimeInterval kViewportAnimDuration = 0.28;
// Black-glass tuning: tint over the behind-window blur and the hairline frame
// traced around the window edge.
static const CGFloat kGlassTintAlpha = 0.5;
static const CGFloat kWindowBorderAlpha = 0.12;
static const CGFloat kWindowCornerRadiusFallback = 12.0;
// Tab hover card: dwell time on a pill before the card appears, and its
// preferred width (shrinks in narrow windows).
static const NSTimeInterval kHoverCardDelay = 1.0;
static const CGFloat kHoverCardWidth = 320.0;

// Every emphasized control border — selected pill, hover, keyboard focus,
// address-editing ring, the "+" button — is the same 1pt #666666 hairline.
static NSColor* BroControlBorderColor(void) {
  return [NSColor colorWithWhite:0x66 / 255.0 alpha:1.0];
}

// Global references
static BroWindow* g_main_window = nil;
static BroToolbar* g_toolbar = nil;
static BroTabBar* g_tab_bar = nil;

// Map browser IDs to their container views
static NSMutableDictionary<NSNumber*, NSView*>* g_browser_views = nil;

// Tabs currently on a blank page (about:blank or no committed URL yet). Their
// container stays hidden even while active so the glass window shows through
// as the new-tab state.
static NSMutableSet<NSNumber*>* g_blank_tab_ids = nil;

// Recently closed tabs' URLs, oldest first, for Reopen Closed Tab
// (Cmd+Shift+T). Blank/new-tab pages are not recorded.
static const NSUInteger kMaxClosedTabHistory = 10;
static NSMutableArray<NSString*>* g_closed_tab_urls = nil;

// Black tint layered over the behind-window blur. Translucent (frosted glass)
// while the active tab is blank; fully opaque once a real page is showing so
// the desktop no longer glows through the chrome.
static NSView* g_glass_tint_view = nil;

// Containers created for incoming popup browsers, keyed by popup ID. Entries
// are removed when the popup's browser is adopted as a tab, or on abort.
static NSMutableDictionary<NSNumber*, NSView*>* g_pending_popup_containers = nil;

// Forward declaration of tab creation functions (implemented after BroWindow)
static void CreateNewBrowserTab(void);
static void CreateNewBrowserTabWithURL(const std::string& url);

// The main window's browser container (overlay parent for the tab hover
// card); nil before the window exists. Implemented after BroWindow.
static NSView* BroBrowserContainerView(void);

// Implemented with the closed-tab-history helpers; declared here for the tab
// strip's hover card.
static BOOL BroURLIsBlank(NSString* url);

// Reframes every per-tab container for its own viewport mode (mobile
// emulation is per-tab).
static void UpdateChromeLayout(void);

// Animates the window between its desktop frame and a shell that hugs the
// mobile viewport, tracking the active tab's viewport mode.
static void UpdateWindowForViewportMode(BOOL mobile, BOOL animate);

// Desktop frame to restore when leaving mobile layout; NSZeroRect = none
// saved. Saved only when empty and cleared only when a desktop restore
// completes, so interrupted toggle cycles never overwrite the original.
static NSRect g_saved_desktop_frame = NSZeroRect;
// Whether the shell currently hugs the mobile viewport (set at animation
// start, so re-entrant calls see consistent state).
static BOOL g_window_in_mobile_layout = NO;
// Stale-completion guard: a superseded animation must not restore masks.
static int g_viewport_anim_token = 0;

// True if the given tab has mobile emulation active.
static BOOL TabIsMobile(int browser_id) {
  BroHandler* handler = BroHandler::GetInstance();
  return handler && handler->IsTabMobile(browser_id);
}

// Display-only host for a URL: the host with any leading "www." removed.
// Falls back to the raw string when the URL has no parseable host. Never used
// for navigation; BroToolbar.fullURL / BroTabView.tabURL keep the canonical
// URL.
static NSString* BroDisplayHostForURL(NSString* urlString) {
  NSString* host = [NSURL URLWithString:urlString ?: @""].host;
  if (host.length == 0) {
    return urlString ?: @"";
  }
  if (host.length > 4 && [host.lowercaseString hasPrefix:@"www."]) {
    return [host substringFromIndex:4];
  }
  return host;
}

// Implicit-animation actions so state changes (hover/focus/active) fade
// instead of snapping. Backing layers suppress implicit animations by
// default; installing explicit actions re-enables them for these keys.
static NSDictionary* BroLayerTransitionActions(void) {
  NSMutableDictionary* actions = [NSMutableDictionary dictionary];
  for (NSString* key in @[ @"borderColor", @"backgroundColor", @"borderWidth" ]) {
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:key];
    fade.duration = 0.15;
    fade.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    actions[key] = fade;
  }
  return actions;
}

#pragma mark - BroFaviconLoader

// Fetches and caches favicons off the main thread. Replaces the previous
// blocking -[NSImage initWithContentsOfURL:] which performed synchronous
// network I/O on a shared GCD queue with no cache, dedup, or timeout.
@interface BroFaviconLoader : NSObject
+ (instancetype)sharedLoader;
// Completion is always invoked on the main thread. Passes nil on failure.
- (void)fetchFavicon:(NSString*)urlString
          completion:(void (^)(NSImage* image))completion;
@end

@implementation BroFaviconLoader {
  NSURLSession* session_;
  NSCache<NSString*, NSImage*>* cache_;
  // URLs that recently failed; skipped so a 404 favicon isn't refetched on
  // every navigation.
  NSMutableSet<NSString*>* failed_;
  // In-flight dedup: completions waiting on a URL already being fetched.
  // Main-thread only.
  NSMutableDictionary<NSString*, NSMutableArray<void (^)(NSImage*)>*>* inflight_;
}

+ (instancetype)sharedLoader {
  static BroFaviconLoader* shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[BroFaviconLoader alloc] init];
  });
  return shared;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    NSURLSessionConfiguration* config =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // Favicons must never hold sockets long.
    config.timeoutIntervalForRequest = 8;
    config.timeoutIntervalForResource = 15;
    session_ = [NSURLSession sessionWithConfiguration:config];
    cache_ = [[NSCache alloc] init];
    cache_.countLimit = 100;
    failed_ = [NSMutableSet set];
    inflight_ = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)fetchFavicon:(NSString*)urlString
          completion:(void (^)(NSImage*))completion {
  NSImage* cached = [cache_ objectForKey:urlString];
  if (cached) {
    completion(cached);
    return;
  }
  if ([failed_ containsObject:urlString]) {
    completion(nil);
    return;
  }
  NSURL* url = [NSURL URLWithString:urlString];
  if (!url) {
    completion(nil);
    return;
  }

  NSMutableArray* waiters = inflight_[urlString];
  if (waiters) {
    [waiters addObject:[completion copy]];
    return;
  }
  inflight_[urlString] = [NSMutableArray arrayWithObject:[completion copy]];

  NSURLSessionDataTask* task = [session_
        dataTaskWithURL:url
      completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        // Decode off-main on the session's queue; only delivery hops to main.
        NSImage* image = nil;
        if (!error && data.length > 0) {
          image = [[NSImage alloc] initWithData:data];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          if (image) {
            [self->cache_ setObject:image forKey:urlString];
          } else {
            [self->failed_ addObject:urlString];
          }
          NSArray* pending = self->inflight_[urlString];
          [self->inflight_ removeObjectForKey:urlString];
          for (void (^waiter)(NSImage*) in pending) {
            waiter(image);
          }
        });
      }];
  [task resume];
}

@end

#pragma mark - BroHoverButton

// Icon button with hover/pressed/selected backgrounds, a pointing-hand
// cursor, and keyboard focus (tabbable even when the system's Full Keyboard
// Access setting is off).
@interface BroHoverButton : NSButton
// Persistent "selected" background for toggle buttons (viewport modes).
@property (nonatomic, assign) BOOL selectedState;
// Resting border, restored when the white keyboard-focus ring goes away.
@property (nonatomic, assign) CGFloat baseBorderWidth;
@property (nonatomic, strong) NSColor* baseBorderColor;
@end

@implementation BroHoverButton {
  BOOL hovered_;
  BOOL pressed_;
  BOOL focused_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6.0;
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
    alpha = (self.enabled && hovered_) ? 0.14 : 0.10;
  } else if (self.enabled && hovered_) {
    alpha = 0.08;
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

// Declared ahead of BroToolbar so the toolbar can flip the host pill's
// editingAddress flag when the address field gains/loses its editor.
@interface BroTabView : NSView
@property (nonatomic, assign) int browserId;
@property (nonatomic, strong) NSImageView* faviconView;
@property (nonatomic, strong) NSProgressIndicator* loadingSpinner;
@property (nonatomic, strong) NSTextField* titleLabel;
@property (nonatomic, strong) NSButton* closeButton;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL isLoading;
// NO on a lone tab: closing it would close the window, so the pill hides ✕.
@property (nonatomic, assign) BOOL closable;
// YES while the hosted address field is being edited; keeps the focused
// border through hover/layout appearance refreshes.
@property (nonatomic, assign) BOOL editingAddress;
// YES once the pill is too narrow for text: favicon only, centered.
@property (nonatomic, assign) BOOL iconOnly;
@property (nonatomic, copy) NSString* tabURL;
// Page title for the hover card and accessibility. Not a native toolTip:
// the glass hover card replaces the system tooltip, and setting both would
// show two overlapping popups.
@property (nonatomic, copy) NSString* pageTitle;
// <meta name=description> content fetched via DevTools for the hover card;
// nil until fetched (empty string = fetched, page has none). Cleared whenever
// tabURL changes.
@property (nonatomic, copy) NSString* pageDescription;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL selectAction;
@property (nonatomic, assign) SEL closeAction;
- (void)setFaviconURL:(NSString*)urlString;
- (void)setLoading:(BOOL)loading;
- (void)setTabURL:(NSString*)url;
- (void)attachAddressField:(NSTextField*)field;
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
    _backButton.toolTip = @"Back (⌘[)";
    [self addSubview:_backButton];
    x += kButtonSize + kButtonSpacing;

    _forwardButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                            icon:RadixIconArrowRight
                                          action:@selector(goForward:)
                                           label:@"Forward"];
    _forwardButton.toolTip = @"Forward (⌘])";
    [self addSubview:_forwardButton];
    x += kButtonSize + kButtonSpacing;

    _refreshButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                            icon:RadixIconReload
                                          action:@selector(refresh:)
                                           label:@"Reload page"];
    _refreshButton.toolTip = @"Reload page (⌘R)";
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
    // Long URLs/hosts show an ellipsis at rest; the field editor still
    // scrolls while typing.
    _addressField.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    _addressField.cell.truncatesLastVisibleLine = YES;
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
    // The selected toggle is disabled but must keep its bright tint, so don't
    // let AppKit dim the icon.
    ((NSButtonCell*)_mobileButton.cell).imageDimsWhenDisabled = NO;
    ((NSButtonCell*)_desktopButton.cell).imageDimsWhenDisabled = NO;
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
  UpdateWindowForViewportMode(mobile, YES);
}

- (void)setViewportMode:(BOOL)mobile {
  NSColor* active = [NSColor whiteColor];
  NSColor* inactive = [NSColor colorWithWhite:1.0 alpha:0.35];
  _desktopButton.contentTintColor = mobile ? inactive : active;
  _mobileButton.contentTintColor = mobile ? active : inactive;
  _desktopButton.selectedState = !mobile;
  _mobileButton.selectedState = mobile;

  // The mode already in effect is inert: no hover, no click, no tab stop.
  BroHoverButton* selected = mobile ? _mobileButton : _desktopButton;
  BroHoverButton* other = mobile ? _desktopButton : _mobileButton;
  selected.enabled = NO;
  other.enabled = YES;
  if (self.window.firstResponder == selected) {
    [self.window makeFirstResponder:other];
  }
}

#pragma mark - NSTextFieldDelegate

- (void)addressFieldDidFocus {
  // Show the full URL for editing; the host pill shows the focused look
  // (gray hairline border, pure white text) from click-in through typing.
  if (_fullURL.length > 0) {
    _addressField.stringValue = _fullURL;
  }
  if ([_addressField.superview isKindOfClass:[BroTabView class]]) {
    ((BroTabView*)_addressField.superview).editingAddress = YES;
  }
  _addressField.textColor = [NSColor whiteColor];
  dispatch_async(dispatch_get_main_queue(), ^{
    NSTextView* editor = (NSTextView*)[self.addressField currentEditor];
    if ([editor isKindOfClass:[NSTextView class]]) {
      editor.insertionPointColor = [NSColor whiteColor];
      editor.textColor = [NSColor whiteColor];
      editor.drawsBackground = NO;
      // Selection inverts against the dark chrome: a white highlight with
      // near-black glyphs, instead of the system's blue-on-white.
      editor.selectedTextAttributes = @{
        NSBackgroundColorAttributeName : [NSColor whiteColor],
        NSForegroundColorAttributeName :
            [NSColor colorWithWhite:0x11 / 255.0 alpha:1.0],
      };
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
    if ([_addressField.superview isKindOfClass:[BroTabView class]]) {
      ((BroTabView*)_addressField.superview).editingAddress = NO;
    }
    _addressField.textColor = [NSColor labelColor];
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
  // Blank pages keep the field empty rather than showing "about:blank".
  if ([url isEqualToString:@"about:blank"]) {
    url = @"";
  }
  self.fullURL = url ?: @"";
  // Don't clobber text the user is currently typing.
  if ([_addressField currentEditor]) {
    return;
  }
  [self displayCompactURL];
}

// Shows just the host (like the mockup); the full URL appears on focus.
- (void)displayCompactURL {
  _addressField.stringValue = BroDisplayHostForURL(_fullURL);
}

@end

#pragma mark - BroTabView

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
// Activates the tab `offset` slots from the active one, wrapping around.
// Unlike focusTabRelativeTo:offset: (keyboard focus, clamped at the ends),
// this switches the active browser.
- (void)activateTabRelativeToActiveWithOffset:(NSInteger)offset;
// Drag-to-reorder: a pill arms on mouse-down, starts dragging once the mouse
// moves past a small threshold, and reports on mouse-up whether a drag
// actually happened (a plain click if not).
- (void)beginPotentialDragForTab:(BroTabView*)tab withEvent:(NSEvent*)event;
- (void)dragTab:(BroTabView*)tab withEvent:(NSEvent*)event;
- (BOOL)endDragForTab:(BroTabView*)tab;
// Hover card: pills report enter/leave; the bar debounces the dwell, shows
// the card, and hides it on click/drag/close/switch/resize.
- (void)tabHoverBegan:(BroTabView*)tab;
- (void)tabHoverEnded:(BroTabView*)tab;
- (void)hideHoverCard;
- (void)updateTabDescription:(int)browserId description:(NSString*)desc;
@end

@implementation BroTabView {
  BOOL hovered_;
  BOOL focused_;
  BOOL wasActiveAtMouseDown_;
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
    // Single-line mode matches the address field's cell so the text doesn't
    // shift when the label swaps for the field on tab activation.
    _titleLabel.cell.usesSingleLineMode = YES;
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
    closeButton.layer.cornerRadius = 4.0;
    closeButton.target = self;
    closeButton.action = @selector(handleClose:);
    closeButton.autoresizingMask = NSViewMinXMargin;
    closeButton.accessibilityLabel = @"Close tab";
    closeButton.toolTip = @"Close tab (⌘W)";
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

  NSUInteger generation = ++faviconGeneration_;
  __weak BroTabView* weakSelf = self;
  [[BroFaviconLoader sharedLoader]
      fetchFavicon:urlString
        completion:^(NSImage* image) {
          BroTabView* strongSelf = weakSelf;
          if (!strongSelf || !image ||
              strongSelf->faviconGeneration_ != generation) {
            return;
          }
          strongSelf.faviconView.image = image;
          strongSelf.faviconView.contentTintColor = nil;
        }];
}

- (void)setTabURL:(NSString*)url {
  NSString* newURL = [url copy] ?: @"";
  if (![_tabURL isEqualToString:newURL]) {
    // The cached meta description belongs to the old page.
    _pageDescription = nil;
  }
  _tabURL = newURL;
  _titleLabel.stringValue = BroDisplayHostForURL(_tabURL);
}

// Hosts the toolbar's shared address field (this pill is the active tab).
// layoutPillContents owns the geometry — attaching to a collapsed square and
// letting autoresizing stretch the field from a negative width drifted it off
// the text inset and put it on top of the favicon.
- (void)attachAddressField:(NSTextField*)field {
  field.autoresizingMask = NSViewNotSizable;
  [self addSubview:field];
  _titleLabel.hidden = YES;
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
  _titleLabel.hidden = _iconOnly || _isActive;

  // Text runs from the favicon's right edge to just inside the ✕ (or the
  // pill's edge when there is no room for one). Clamped at zero so a collapsed
  // pill can't produce a negative width.
  CGFloat textRight = _closable ? 26.0 : 10.0;
  NSRect textFrame =
      NSMakeRect(32, (self.bounds.size.height - 18) / 2.0,
                 MAX(0.0, self.bounds.size.width - 32 - textRight), 18);
  _titleLabel.frame = textFrame;
  for (NSView* v in self.subviews) {
    if ([v isKindOfClass:[BroAddressField class]]) {
      v.hidden = _iconOnly;
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

// Selected (active) pills are brightest; hovered inactive pills sit between
// the selected and resting looks. Selection, hover, keyboard focus, and the
// address-editing state all share the same 1pt gray hairline; only resting
// inactive pills are fainter.
- (void)updateAppearance {
  if (_isActive) {
    self.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.08].CGColor;
    self.layer.borderColor = BroControlBorderColor().CGColor;
    _titleLabel.textColor = [NSColor labelColor];
  } else {
    CGFloat bg = hovered_ ? 0.06 : 0.03;
    self.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:bg].CGColor;
    self.layer.borderColor =
        (hovered_ || focused_)
            ? BroControlBorderColor().CGColor
            : [NSColor colorWithWhite:1.0 alpha:0.08].CGColor;
    _titleLabel.textColor = [NSColor secondaryLabelColor];
    // The address field only lives in the active pill, so the label comes
    // back — unless the pill is collapsed to its favicon.
    _titleLabel.hidden = _iconOnly;
  }
  // The active pill always shows ✕; inactive pills reveal it on hover or
  // keyboard focus.
  _closeButton.hidden = !(_closable && (_isActive || hovered_ || focused_));
}

- (void)setClosable:(BOOL)closable {
  _closable = closable;
  [self updateAppearance];
  // Text width depends on whether a ✕ is reserving space.
  [self layoutPillContents];
}

- (void)setIsActive:(BOOL)isActive {
  _isActive = isActive;
  [self updateAppearance];
  [self layoutPillContents];
}

- (void)setEditingAddress:(BOOL)editingAddress {
  _editingAddress = editingAddress;
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
  NSString* host = _titleLabel.stringValue;
  if (host.length > 0) {
    return host;
  }
  return self.pageTitle.length > 0 ? self.pageTitle : @"New Tab";
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

// Floating glass card shown after dwelling on a tab pill: page title, full
// URL, and (when available) the page's meta description. Click-through — it
// overlaps the browser view and must never intercept the mouse.
@interface BroTabHoverCard : NSView
// Populates the labels and resizes self to fit; caller positions the frame.
- (void)setTitle:(NSString*)title
             url:(NSString*)url
     pageDescription:(NSString*)desc
           width:(CGFloat)width;
@end

@implementation BroTabHoverCard {
  NSTextField* titleLabel_;
  NSTextField* urlLabel_;
  NSTextField* descriptionLabel_;
}

static NSTextField* BroHoverCardLabel(NSFont* font, CGFloat whiteAlpha) {
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
    self.layer.cornerRadius = 8.0;
    // Slightly lighter and more opaque than the zoom HUD so the card stays
    // readable over dark page content.
    self.layer.backgroundColor =
        [NSColor colorWithWhite:0.18 alpha:0.96].CGColor;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor =
        [NSColor colorWithWhite:1.0 alpha:kWindowBorderAlpha].CGColor;

    titleLabel_ = BroHoverCardLabel([NSFont boldSystemFontOfSize:12.0], 1.0);
    urlLabel_ = BroHoverCardLabel([NSFont systemFontOfSize:11.0], 0.55);
    descriptionLabel_ = BroHoverCardLabel([NSFont systemFontOfSize:11.0], 0.75);
    descriptionLabel_.lineBreakMode = NSLineBreakByWordWrapping;
    descriptionLabel_.cell.wraps = YES;
    [self addSubview:titleLabel_];
    [self addSubview:urlLabel_];
    [self addSubview:descriptionLabel_];
  }
  return self;
}

- (NSView*)hitTest:(NSPoint)point {
  return nil;
}

- (void)setTitle:(NSString*)title
             url:(NSString*)url
     pageDescription:(NSString*)desc
           width:(CGFloat)width {
  const CGFloat padX = 12.0;
  const CGFloat padY = 10.0;
  const CGFloat rowGap = 3.0;
  const CGFloat textWidth = width - padX * 2;

  titleLabel_.stringValue = title ?: @"";
  urlLabel_.stringValue = url ?: @"";
  descriptionLabel_.stringValue = desc ?: @"";
  descriptionLabel_.hidden = desc.length == 0;

  CGFloat titleHeight = ceil([titleLabel_.cell cellSizeForBounds:
      NSMakeRect(0, 0, CGFLOAT_MAX, CGFLOAT_MAX)].height);
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

  CGFloat height = padY * 2 + titleHeight + rowGap + urlHeight;
  if (descriptionHeight > 0) {
    height += rowGap + descriptionHeight;
  }

  // Flipped-less (default) coords: title on top.
  CGFloat y = padY;
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
  BroTabHoverCard* hoverCard_;
  NSTimer* hoverCardTimer_;
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
    _addTabButton.layer.cornerRadius = 4.0;
    _addTabButton.baseBorderWidth = 1.0;
    _addTabButton.baseBorderColor = BroControlBorderColor();
    _addTabButton.target = self;
    _addTabButton.action = @selector(createNewTab:);
    _addTabButton.accessibilityLabel = @"New tab";
    _addTabButton.toolTip = @"New tab (⌘N)";
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
  tab.pageTitle = title ?: @"New Tab";
  tab.target = self;
  tab.selectAction = @selector(tabSelected:);
  tab.closeAction = @selector(tabClosed:);
  [_tabs addObject:tab];
  [self addSubview:tab];

  // The new pill starts at its final slot fully transparent and fades in
  // while its neighbors and the "+" button slide over to make room.
  CGFloat tabWidth = [self fittedTabWidth];
  tab.frame = NSMakeRect((_tabs.count - 1) * (tabWidth + 8.0), pillY, tabWidth,
                         kTabPillHeight);
  tab.alphaValue = 0.0;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.22;
    ctx.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self applyTabLayout:YES];
    tab.animator.alphaValue = 1.0;
  } completionHandler:nil];
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
  // pills it passes.
  CGFloat tabWidth = tab.frame.size.width;
  CGFloat slotWidth = [self dragSlotWidth];
  CGFloat maxX = ((CGFloat)_tabs.count - 1) * slotWidth;
  CGFloat newX = MIN(MAX(p.x - dragOffsetX_, 0.0), maxX);
  tab.frame = NSMakeRect(newX, pillY, tabWidth, kTabPillHeight);

  // When the pill is carried past a neighbor's slot, the array reorders and
  // everyone else slides to their new home (the dragged pill keeps following
  // the mouse; applyTabLayout skips it while a drag is live).
  NSInteger current = [_tabs indexOfObject:tab];
  NSInteger target = lround(newX / slotWidth);
  target = MIN(MAX(target, (NSInteger)0), (NSInteger)_tabs.count - 1);
  if (target != current) {
    [_tabs removeObjectAtIndex:current];
    [_tabs insertObject:tab atIndex:target];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = 0.15;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [self applyTabLayout:YES];
    } completionHandler:nil];
  }
}

- (BOOL)endDragForTab:(BroTabView*)tab {
  if (tab != draggingTab_) {
    return NO;
  }
  BOOL didDrag = dragging_;
  draggingTab_ = nil;
  dragging_ = NO;
  if (didDrag) {
    // Balances the push/disable from the first drag event.
    [NSCursor pop];
    [self.window enableCursorRects];
    [[NSCursor arrowCursor] set];
    // Snap the released pill into its slot, then drop it back to pill level.
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = 0.15;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [self applyTabLayout:YES];
    } completionHandler:^{
      tab.layer.zPosition = 0.0;
    }];
    [self.window recalculateKeyViewLoop];
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
      [self applyTabLayout:YES];
    } completionHandler:^{
      [tabToRemove removeFromSuperview];
    }];
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
    [g_toolbar.addressField removeFromSuperview];
    if (activeTab) {
      [activeTab attachAddressField:g_toolbar.addressField];
    }
    // The viewport toggles reflect the active tab's own emulation state.
    [g_toolbar setViewportMode:TabIsMobile(browserId)];
  }

  // In a collapsed strip the newly active pill grows out of its square so its
  // URL can be read and typed, and the one it replaced shrinks back. Animate
  // that swap; when the strip is roomy every pill is already the same width
  // and there is nothing to move.
  if ([self isCollapsed] && !dragging_) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = 0.18;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [self applyTabLayout:YES];
    } completionHandler:nil];
  }
}

- (void)updateTabTitle:(int)browserId title:(NSString*)title {
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      // Pills display the host; the page title shows in the hover card.
      tab.pageTitle = title ?: @"New Tab";
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
  return self.frame.size.width - (kAddTabButtonSize + 8.0);
}

// Fits pills to the available strip width (minus the "+" button), capped at
// the mockup's pill width. Only meaningful while the strip is roomy — once
// pills would go narrower than kTabPillTextMinWidth the layout switches to
// squares and this stops describing every pill (see -tabWidths).
- (CGFloat)fittedTabWidth {
  NSUInteger count = MAX(_tabs.count, (NSUInteger)1);
  CGFloat fitWidth = [self availableStripWidth] / count - 8.0;
  return MIN(MAX(fitWidth, kTabPillSquareWidth), kTabPillMaxWidth);
}

// YES once an even split would leave no room for text: pills become squares.
- (BOOL)isCollapsed {
  NSUInteger count = MAX(_tabs.count, (NSUInteger)1);
  return [self availableStripWidth] / count - 8.0 < kTabPillTextMinWidth;
}

// Width of one drag slot. Collapsed, the pills the dragged pill travels past
// are squares, so slots are square-sized even though the carried pill is not.
- (CGFloat)dragSlotWidth {
  return ([self isCollapsed] ? kTabPillSquareWidth : [self fittedTabWidth]) + 8.0;
}

// Per-pill widths in strip order. Uniform while there is room; collapsed, every
// inactive pill is a square and the active one takes the leftover space so its
// URL stays readable and editable.
- (NSArray<NSNumber*>*)tabWidths {
  NSMutableArray<NSNumber*>* widths =
      [NSMutableArray arrayWithCapacity:_tabs.count];
  if (![self isCollapsed]) {
    CGFloat uniform = [self fittedTabWidth];
    for (NSUInteger i = 0; i < _tabs.count; i++) {
      [widths addObject:@(uniform)];
    }
    return widths;
  }
  CGFloat squares = (CGFloat)(_tabs.count - 1) * (kTabPillSquareWidth + 8.0);
  CGFloat slack = [self availableStripWidth] - squares - 8.0;
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
    // title; narrower still they keep only the favicon.
    tab.closable = _tabs.count > 1 && tabWidth >= kTabPillCloseMinWidth;
    tab.iconOnly = tabWidth < kTabPillTextMinWidth;
    NSRect target = NSMakeRect(x, pillY, tabWidth, kTabPillHeight);
    if (dragging_ && tab == draggingTab_) {
      // The dragged pill follows the mouse; its slot stays reserved.
    } else if (animated) {
      tab.animator.frame = target;
    } else {
      tab.frame = target;
    }
    x += tabWidth + 8.0;
  }

  NSRect addTarget =
      NSMakeRect(x, (self.frame.size.height - kAddTabButtonSize) / 2.0,
                 kAddTabButtonSize, kAddTabButtonSize);
  if (animated) {
    _addTabButton.animator.frame = addTarget;
  } else {
    _addTabButton.frame = addTarget;
  }
}

- (void)layoutTabs {
  [self applyTabLayout:NO];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  [self layoutTabs];
  // A resize invalidates the card's position; hiding beats tracking it.
  [self hideHoverCard];
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
  [hoverCardTimer_ invalidate];
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
  [self hideHoverCard];
}

- (void)hideHoverCard {
  [hoverCardTimer_ invalidate];
  hoverCardTimer_ = nil;
  hoverCard_.hidden = YES;
  hoverCardTabId_ = -1;
}

// Title shown on the card; falls back to the display host for pages that
// never reported one.
- (NSString*)hoverCardTitleForTab:(BroTabView*)tab {
  return tab.pageTitle.length > 0 ? tab.pageTitle
                                  : BroDisplayHostForURL(tab.tabURL);
}

- (void)showHoverCardForTab:(BroTabView*)tab {
  NSView* container = BroBrowserContainerView();
  if (dragging_ || !container) {
    return;
  }
  if (!hoverCard_) {
    hoverCard_ = [[BroTabHoverCard alloc] initWithFrame:NSZeroRect];
  }
  // Re-add last on every show: tab containers created since the previous
  // hover stack above the card, and the native CEF views inside them would
  // occlude it.
  [hoverCard_ removeFromSuperview];
  [container addSubview:hoverCard_];
  hoverCardTabId_ = tab.browserId;

  CGFloat width = MIN(kHoverCardWidth, NSWidth(container.bounds) - 16.0);
  if (width < 100.0) {
    return;  // window too narrow for a useful card
  }
  if (BroURLIsBlank(tab.tabURL)) {
    // Blank tabs have no URL or metadata worth showing; the card invites
    // instead (mirrors the address field's empty state).
    [hoverCard_ setTitle:@"New Tab"
                     url:@"Ask anything…"
         pageDescription:nil
                   width:width];
  } else {
    [hoverCard_ setTitle:[self hoverCardTitleForTab:tab]
                     url:tab.tabURL
         pageDescription:tab.pageDescription
                   width:width];
  }
  [self positionHoverCardForTab:tab];
  hoverCard_.hidden = NO;

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
- (void)positionHoverCardForTab:(BroTabView*)tab {
  NSView* container = hoverCard_.superview;
  if (!container || tab.superview != self) {
    return;
  }
  NSRect pill = [container convertRect:tab.bounds fromView:tab];
  NSSize size = hoverCard_.frame.size;
  CGFloat x = MIN(NSMinX(pill), NSMaxX(container.bounds) - size.width - 8.0);
  x = MAX(x, 8.0);
  CGFloat y = NSMaxY(container.bounds) - size.height - 6.0;
  hoverCard_.frame = NSMakeRect(x, y, size.width, size.height);
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
                       url:tab.tabURL
           pageDescription:tab.pageDescription
                     width:hoverCard_.frame.size.width];
      [self positionHoverCardForTab:tab];
    }
    break;
  }
}

@end

#pragma mark - BroWindow

// Click-through overlay that draws the 1px hairline frame above everything,
// including the windowed CEF child views.
@interface BroWindowBorderView : NSView
@end

@implementation BroWindowBorderView
- (NSView*)hitTest:(NSPoint)point {
  return nil;
}
@end

// The system frame view already masks the full-size content (including the
// CEF child views) to the window shape, so the hairline only has to trace the
// same curve. The radius varies across macOS releases; probe the frame view.
static CGFloat BroWindowCornerRadius(NSWindow* window) {
  NSView* frameView = window.contentView.superview;  // NSThemeFrame
  if ([frameView respondsToSelector:@selector(cornerRadius)]) {
    CGFloat r = [[frameView valueForKey:@"cornerRadius"] doubleValue];
    if (r > 0.5) {
      return r;
    }
  }
  return kWindowCornerRadiusFallback;
}

@interface BroWindow : NSWindow
@property (nonatomic, strong) NSView* browserContainer;
@property (nonatomic, strong) BroToolbar* navToolbar;
@property (nonatomic, strong) BroTabBar* tabBar;
@property (nonatomic, strong) NSView* borderOverlay;
@end

static NSView* BroBrowserContainerView(void) {
  return g_main_window ? g_main_window.browserContainer : nil;
}

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
    content.state = NSVisualEffectStateActive;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.contentView = content;

    // Black tint over the blur: dark enough to read as black glass, light
    // enough that the desktop clearly glows through the whole window.
    NSView* tint = [[NSView alloc] initWithFrame:frame];
    tint.wantsLayer = YES;
    tint.layer.backgroundColor =
        [[NSColor blackColor] colorWithAlphaComponent:kGlassTintAlpha].CGColor;
    tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:tint];
    g_glass_tint_view = tint;

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

    // Hairline frame on top of everything (added last so it draws above the
    // CEF child views).
    BroWindowBorderView* border = [[BroWindowBorderView alloc] initWithFrame:frame];
    border.wantsLayer = YES;
    border.layer.borderWidth = 1.0;
    border.layer.borderColor =
        [[NSColor whiteColor] colorWithAlphaComponent:kWindowBorderAlpha].CGColor;
    border.layer.cornerRadius = BroWindowCornerRadius(self);
    border.layer.cornerCurve = kCACornerCurveContinuous;
    border.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:border];
    _borderOverlay = border;

    // Initialize browser views dictionary
    g_browser_views = [NSMutableDictionary dictionary];
    g_blank_tab_ids = [NSMutableSet set];
    g_closed_tab_urls = [NSMutableArray array];

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

// Blank pages (and browsers with no committed URL yet) keep their opaque CEF
// view hidden so the glass window shows through instead of a black rectangle.
static BOOL BroURLIsBlank(NSString* url) {
  return url.length == 0 || [url isEqualToString:@"about:blank"];
}

// True while the whole window is occluded (miniaturized or fully covered);
// every tab counts as hidden so even the active one throttles.
static BOOL g_window_occluded = NO;

// Central visibility rule: only the active tab's container is visible, and
// not even that one while the tab is blank (glass new-tab state). The window
// tint follows the same rule: frosted glass on blank tabs, opaque black chrome
// once the active tab shows a real page. Hiding the container NSView is not
// enough for Chromium's occlusion tracking in windowed CEF (measured:
// background tabs kept rendering rAF at ~45fps and timers at ~4.5Hz), so
// hidden containers are detached from the window entirely —
// viewDidMoveToWindow(nil) is the signal the render widget host actually
// honors (measured: rAF frozen, timers at 1Hz).
static void UpdateTabContainerVisibility(int active_browser_id) {
  BroHandler* handler = BroHandler::GetInstance();
  NSView* parent = g_main_window.browserContainer;
  for (NSNumber* key in g_browser_views) {
    BOOL hidden = (key.intValue != active_browser_id) ||
                  [g_blank_tab_ids containsObject:key];
    NSView* container = g_browser_views[key];
    BOOL detached = hidden || g_window_occluded;
    if (detached) {
      // g_browser_views keeps the container (and the CEF view inside it)
      // alive while it is out of the view hierarchy.
      if (container.superview) {
        [container removeFromSuperview];
      }
    } else if (parent && container.superview != parent) {
      [parent addSubview:container];
      ApplyViewportFrameToContainer(container, TabIsMobile(key.intValue));
    }
    container.hidden = hidden;
    if (handler) {
      handler->SetBrowserHidden(key.intValue, detached);
    }
  }
  BOOL glass = g_browser_views[@(active_browser_id)] == nil ||
               [g_blank_tab_ids containsObject:@(active_browser_id)];
  g_glass_tint_view.layer.backgroundColor =
      [[NSColor blackColor]
          colorWithAlphaComponent:glass ? kGlassTintAlpha : 1.0]
          .CGColor;
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

// Resizes the shell to hug the mobile viewport (or back to the saved desktop
// frame), animating the window and the active tab's container as one motion.
static void UpdateWindowForViewportMode(BOOL mobile, BOOL animate) {
  if (!g_main_window) {
    return;
  }
  // In native fullscreen the shell can't hug the viewport; keep the current
  // centered-column behavior. windowDidExitFullScreen: re-syncs afterwards.
  if ((g_main_window.styleMask & NSWindowStyleMaskFullScreen) != 0) {
    UpdateChromeLayout();
    return;
  }
  if (mobile == g_window_in_mobile_layout) {
    UpdateChromeLayout();
    return;
  }
  g_window_in_mobile_layout = mobile;
  const int token = ++g_viewport_anim_token;

  NSScreen* screen = g_main_window.screen ?: [NSScreen mainScreen];
  NSRect current = g_main_window.frame;
  NSRect target;
  if (mobile) {
    if (NSIsEmptyRect(g_saved_desktop_frame)) {
      g_saved_desktop_frame = current;
    }
    g_main_window.minSize = NSMakeSize(kMobileShellWidth, 400);
    NSRect contentRect = NSMakeRect(0, 0, kMobileShellWidth,
                                    kToolbarHeight + kMobileViewportHeight);
    target = [g_main_window frameRectForContentRect:contentRect];
    target.size.height =
        MIN(target.size.height, screen.visibleFrame.size.height);
    // Anchor the top edge and horizontal center.
    target.origin.x = NSMidX(current) - target.size.width / 2.0;
    target.origin.y = NSMaxY(current) - target.size.height;
  } else {
    target = NSIsEmptyRect(g_saved_desktop_frame) ? current
                                                  : g_saved_desktop_frame;
  }
  target = [g_main_window constrainFrameRect:target toScreen:screen];

  // The active container's final frame, in the browser area's final
  // coordinates (mirrors ApplyViewportFrameToContainer).
  NSRect targetContent = [g_main_window contentRectForFrameRect:target];
  CGFloat contentWidth = targetContent.size.width;
  CGFloat contentHeight = targetContent.size.height - kToolbarHeight;
  CGFloat columnWidth = MIN(kMobileViewportWidth, contentWidth);
  NSRect containerTarget =
      mobile ? NSMakeRect((contentWidth - columnWidth) / 2.0, 0, columnWidth,
                          contentHeight)
             : NSMakeRect(0, 0, contentWidth, contentHeight);

  BroHandler* handler = BroHandler::GetInstance();
  int activeId = handler ? handler->GetActiveBrowserId() : -1;
  NSView* activeContainer =
      (activeId >= 0) ? g_browser_views[@(activeId)] : nil;

  void (^finish)(void) = ^{
    // A newer toggle owns the layout now; let its completion do the work.
    if (token != g_viewport_anim_token || !g_main_window) {
      return;
    }
    UpdateChromeLayout();  // exact frames + proper autoresizing masks
    if (!mobile) {
      g_main_window.minSize = NSMakeSize(760, 400);
      g_saved_desktop_frame = NSZeroRect;
    }
  };

  if (!animate) {
    [g_main_window setFrame:target display:YES];
    finish();
    return;
  }

  // Freeze autoresizing on the visible container so the window animation's
  // per-tick autoresize doesn't fight the animator; finish() restores the
  // proper mask via ApplyViewportFrameToContainer.
  activeContainer.autoresizingMask = NSViewNotSizable;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = kViewportAnimDuration;
        ctx.timingFunction = [CAMediaTimingFunction
            functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [[g_main_window animator] setFrame:target display:YES];
        [[activeContainer animator] setFrame:containerTarget];
      }
      completionHandler:finish];
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
  // Blank/unstyled pages render the shell's pure black instead of
  // Chromium's default page background.
  browser_settings.background_color = CefColorSetARGB(255, 0, 0, 0);

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
  CreateNewBrowserTabWithURL("about:blank");
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

  // Ctrl+Tab / Ctrl+Shift+Tab cycle tabs. This cannot be a menu key
  // equivalent: Tab is consumed for focus traversal before the menu pass
  // when the browser view is first responder. Only the main window cycles;
  // DevTools and other windows keep their native behavior.
  if (event.type == NSEventTypeKeyDown && event.keyCode == 48 /* kVK_Tab */ &&
      event.window == g_main_window && g_tab_bar) {
    NSEventModifierFlags mods =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL ctrlOnly =
        (mods & NSEventModifierFlagControl) != 0 &&
        (mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) == 0;
    if (ctrlOnly) {
      [g_tab_bar activateTabRelativeToActiveWithOffset:
                     (mods & NSEventModifierFlagShift) ? -1 : 1];
      return;
    }
  }

  // Cmd+Left/Right = history back/forward. Handled here rather than as menu
  // key equivalents or a CefKeyboardHandler because CEF's windowed mac view
  // never forwards Cmd-modified keys to the renderer, so pages cannot see
  // them anyway. The NSText check keeps line-start/line-end editing in the
  // address bar's field editor.
  if (event.type == NSEventTypeKeyDown &&
      (event.keyCode == 123 /* kVK_LeftArrow */ ||
       event.keyCode == 124 /* kVK_RightArrow */) &&
      event.window == g_main_window &&
      ![g_main_window.firstResponder isKindOfClass:[NSText class]]) {
    NSEventModifierFlags mods =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    // Arrow keys carry the function/numeric-pad flags, so test the modifier
    // keys individually instead of comparing against Command alone.
    BOOL cmdOnly =
        (mods & NSEventModifierFlagCommand) != 0 &&
        (mods & (NSEventModifierFlagShift | NSEventModifierFlagControl |
                 NSEventModifierFlagOption)) == 0;
    if (cmdOnly) {
      BroHandler* handler = BroHandler::GetInstance();
      CefRefPtr<CefBrowser> browser = handler ? handler->GetBrowser() : nullptr;
      if (browser) {
        if (event.keyCode == 123 && browser->CanGoBack()) {
          browser->GoBack();
        } else if (event.keyCode == 124 && browser->CanGoForward()) {
          browser->GoForward();
        }
      }
      return;
    }
  }

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
  [viewMenu addItemWithTitle:@"GPU Benchmark"
                      action:@selector(openGpuBenchmark:)
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

  // Single-window app: Cmd+N means new tab, not new window.
  [fileMenu addItemWithTitle:@"New Tab"
                      action:@selector(newTab:)
               keyEquivalent:@"n"];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  [fileMenu addItemWithTitle:@"Close Tab"
                      action:@selector(closeTab:)
               keyEquivalent:@"w"];
  NSMenuItem* reopenItem = [fileMenu addItemWithTitle:@"Reopen Closed Tab"
                                               action:@selector(reopenClosedTab:)
                                        keyEquivalent:@"t"];
  reopenItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
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

  // Tab cycling. Hidden "{" / "}" alternates cover keyboards where AppKit
  // reports the shifted character instead of the base key (same trick as the
  // Zoom In "+" alternate above).
  [windowMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* prevTabItem = [windowMenu addItemWithTitle:@"Show Previous Tab"
                                                  action:@selector(selectPreviousTab:)
                                           keyEquivalent:@"["];
  prevTabItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  NSMenuItem* nextTabItem = [windowMenu addItemWithTitle:@"Show Next Tab"
                                                  action:@selector(selectNextTab:)
                                           keyEquivalent:@"]"];
  nextTabItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  NSMenuItem* prevTabShifted =
      [[NSMenuItem alloc] initWithTitle:@"Show Previous Tab"
                                 action:@selector(selectPreviousTab:)
                          keyEquivalent:@"{"];
  prevTabShifted.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  prevTabShifted.hidden = YES;
  [windowMenu addItem:prevTabShifted];
  NSMenuItem* nextTabShifted =
      [[NSMenuItem alloc] initWithTitle:@"Show Next Tab"
                                 action:@selector(selectNextTab:)
                          keyEquivalent:@"}"];
  nextTabShifted.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  nextTabShifted.hidden = YES;
  [windowMenu addItem:nextTabShifted];

  // Cmd+1..8 jump to that tab; Cmd+9 jumps to the last tab (tag -1).
  [windowMenu addItem:[NSMenuItem separatorItem]];
  for (NSUInteger i = 0; i < 8; i++) {
    NSMenuItem* tabItem = [windowMenu
        addItemWithTitle:[NSString stringWithFormat:@"Tab %lu",
                                                    (unsigned long)(i + 1)]
                  action:@selector(selectTabAtIndex:)
           keyEquivalent:[NSString stringWithFormat:@"%lu",
                                                    (unsigned long)(i + 1)]];
    tabItem.tag = (NSInteger)i;
  }
  NSMenuItem* lastTabItem = [windowMenu addItemWithTitle:@"Last Tab"
                                                  action:@selector(selectTabAtIndex:)
                                           keyEquivalent:@"9"];
  lastTabItem.tag = -1;

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
  // Blank/unstyled pages render the shell's pure black instead of
  // Chromium's default page background.
  browser_settings.background_color = CefColorSetARGB(255, 0, 0, 0);

  // Window info - embed in the container view
  CefWindowInfo window_info;
  NSRect bounds = browserContainer.bounds;
  window_info.SetAsChild(
      CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(browserContainer),
      CefRect(0, 0, bounds.size.width, bounds.size.height));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  // Create the browser on a blank page; the address bar stays empty.
  std::string url = "about:blank";
  CefBrowserHost::CreateBrowser(window_info, handler, url, browser_settings,
                                nullptr, nullptr);

  if (g_toolbar) {
    [g_toolbar updateURL:@""];
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

- (void)reopenClosedTab:(id)sender {
  NSString* url = g_closed_tab_urls.lastObject;
  if (!url) {
    return;
  }
  [g_closed_tab_urls removeLastObject];
  CreateNewBrowserTabWithURL(std::string([url UTF8String]));
}

// Menu item tag is the tab index (0-based); tag -1 means the last tab.
- (void)selectTabAtIndex:(NSMenuItem*)sender {
  if (!g_tab_bar) {
    return;
  }
  NSInteger count = (NSInteger)g_tab_bar.tabs.count;
  NSInteger index = (sender.tag == -1) ? count - 1 : sender.tag;
  // Re-guard here: tabs can close between menu validation and dispatch.
  if (index < 0 || index >= count) {
    return;
  }
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    handler->SetActiveBrowser(g_tab_bar.tabs[index].browserId);
  }
}

- (void)selectNextTab:(id)sender {
  [g_tab_bar activateTabRelativeToActiveWithOffset:1];
}

- (void)selectPreviousTab:(id)sender {
  [g_tab_bar activateTabRelativeToActiveWithOffset:-1];
}

// The delegate is the responder-chain target for every no-target menu item,
// so the default branch must stay YES to keep the rest auto-enabled.
- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
  SEL action = menuItem.action;
  if (action == @selector(goBack:) || action == @selector(goForward:)) {
    // Main thread == CEF UI thread, so querying the browser directly is safe
    // and never stale (the toolbar's copy updates via dispatch_async).
    BroHandler* handler = BroHandler::GetInstance();
    CefRefPtr<CefBrowser> browser = handler ? handler->GetBrowser() : nullptr;
    if (!browser) {
      return NO;
    }
    return action == @selector(goBack:) ? browser->CanGoBack()
                                        : browser->CanGoForward();
  }
  if (action == @selector(selectTabAtIndex:)) {
    NSInteger count = g_tab_bar ? (NSInteger)g_tab_bar.tabs.count : 0;
    return menuItem.tag == -1 ? count > 0 : menuItem.tag < count;
  }
  if (action == @selector(selectNextTab:) ||
      action == @selector(selectPreviousTab:)) {
    return g_tab_bar && g_tab_bar.tabs.count > 1;
  }
  if (action == @selector(reopenClosedTab:)) {
    return g_closed_tab_urls.count > 0;
  }
  return YES;
}

- (void)openWasmBenchmark:(id)sender {
  NSString* path = [[NSBundle mainBundle] pathForResource:@"wasm-bench"
                                                   ofType:@"html"];
  if (path) {
    NSURL* url = [NSURL fileURLWithPath:path];
    CreateNewBrowserTabWithURL([[url absoluteString] UTF8String]);
  }
}

- (void)openGpuBenchmark:(id)sender {
  NSString* path = [[NSBundle mainBundle] pathForResource:@"gpu-bench"
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
  [g_blank_tab_ids removeAllObjects];
  [g_closed_tab_urls removeAllObjects];
}

// Miniaturized or fully covered windows report as non-visible; treat every
// tab as hidden so even the foreground one stops rendering, and restore the
// active tab when the window becomes visible again.
- (void)windowDidChangeOcclusionState:(NSNotification*)notification {
  NSWindow* window = notification.object;
  if (window != g_main_window) {
    return;
  }
  BOOL occluded =
      (window.occlusionState & NSWindowOcclusionStateVisible) == 0;
  if (occluded == g_window_occluded) {
    return;
  }
  g_window_occluded = occluded;
  BroHandler* handler = BroHandler::GetInstance();
  UpdateTabContainerVisibility(handler ? handler->GetActiveBrowserId() : -1);
}

// Fullscreen squares off the window corners, so the rounded hairline frame
// would float inside them; hide it for the duration.
- (void)windowWillEnterFullScreen:(NSNotification*)notification {
  g_main_window.borderOverlay.hidden = YES;
}

- (void)windowWillExitFullScreen:(NSNotification*)notification {
  g_main_window.borderOverlay.hidden = NO;
}

// While fullscreen the shell deliberately doesn't hug the mobile viewport;
// re-sync it to the active tab's mode once fullscreen ends.
- (void)windowDidExitFullScreen:(NSNotification*)notification {
  BroHandler* handler = BroHandler::GetInstance();
  int activeId = handler ? handler->GetActiveBrowserId() : -1;
  if (activeId >= 0) {
    UpdateWindowForViewportMode(TabIsMobile(activeId), YES);
  }
}

@end

#pragma mark - Callback Functions for Handler

// The CEF UI thread is the main thread here, so pure UI-update callbacks run
// their block inline instead of paying a dispatch (block alloc + a run-loop
// turn of latency) per load event. Lifecycle callbacks that tear down views or
// create browsers keep their deliberate dispatch_async deferral — running
// those synchronously re-enters CEF from inside its own callbacks.
static void BroRunOnMain(void (^block)(void)) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

// These functions are called from BroHandler to update the UI
void UpdateNavigationState(bool canGoBack, bool canGoForward) {
  BroRunOnMain(^{
    if (g_toolbar) {
      [g_toolbar updateNavigationState:canGoBack canGoForward:canGoForward];
    }
  });
}

void UpdateURL(const std::string& url) {
  // Convert before dispatching: on the async fallback path the block would
  // otherwise capture the std::string parameter by reference, which dangles
  // once the caller returns (use-after-free; crashed with garbage/NULL
  // c_str()).
  NSString* urlStr = [NSString stringWithUTF8String:url.c_str()] ?: @"";
  BroRunOnMain(^{
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

  // New browsers usually arrive before their first commit (empty URL), so
  // they start as glass and unhide when a real URL commits.
  NSString* urlStr = [NSString stringWithUTF8String:url.c_str()] ?: @"";
  if (BroURLIsBlank(urlStr)) {
    [g_blank_tab_ids addObject:@(browser_id)];
  }

  // Add tab to tab bar
  if (g_tab_bar) {
    [g_tab_bar addTabWithBrowserId:browser_id title:@"New Tab"];
    [g_tab_bar updateTabURL:browser_id url:urlStr];
    [g_tab_bar setActiveTab:browser_id];
  }

  UpdateTabContainerVisibility(browser_id);

  // A newly adopted tab becomes active without going through
  // OnActiveTabChanged; the shell follows its viewport mode (desktop).
  UpdateWindowForViewportMode(TabIsMobile(browser_id), YES);
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
    [g_blank_tab_ids removeObject:@(browser_id)];
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
  BroRunOnMain(^{
    if (g_tab_bar) {
      [g_tab_bar updateTabTitle:browser_id title:titleStr];
    }
  });
}

void OnTabDescriptionAvailable(int browser_id, const std::string& description) {
  // Convert before dispatching (see UpdateURL).
  NSString* descStr =
      [NSString stringWithUTF8String:description.c_str()] ?: @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_tab_bar) {
      [g_tab_bar updateTabDescription:browser_id description:descStr];
    }
  });
}

void OnTabURLChanged(int browser_id, const std::string& url) {
  // Convert before dispatching (see UpdateURL).
  NSString* urlStr = [NSString stringWithUTF8String:url.c_str()] ?: @"";
  BroRunOnMain(^{
    if (g_tab_bar) {
      [g_tab_bar updateTabURL:browser_id url:urlStr];
    }

    // Commit-time blank/loaded transition: unhide the CEF view for real
    // pages, return to glass when the tab navigates back to about:blank.
    if (BroURLIsBlank(urlStr)) {
      [g_blank_tab_ids addObject:@(browser_id)];
    } else {
      [g_blank_tab_ids removeObject:@(browser_id)];
    }
    BroHandler* handler = BroHandler::GetInstance();
    if (handler) {
      UpdateTabContainerVisibility(handler->GetActiveBrowserId());
    }
  });
}

void OnTabFaviconChanged(int browser_id, const std::string& favicon_url) {
  // Convert before dispatching (see UpdateURL).
  NSString* urlStr = [NSString stringWithUTF8String:favicon_url.c_str()] ?: @"";
  BroRunOnMain(^{
    if (g_tab_bar) {
      [g_tab_bar updateTabFavicon:browser_id faviconURL:urlStr];
    }
  });
}

void OnTabLoadingChanged(int browser_id, bool is_loading) {
  BroRunOnMain(^{
    if (g_tab_bar) {
      [g_tab_bar updateTabLoading:browser_id loading:is_loading];
    }
  });
}

void OnTabClosed(int browser_id) {
  dispatch_async(dispatch_get_main_queue(), ^{
    // Remove from tab bar
    if (g_tab_bar) {
      // Record the URL for Reopen Closed Tab while the pill still exists.
      // Blank/new-tab pages aren't worth reopening.
      for (BroTabView* tab in g_tab_bar.tabs) {
        if (tab.browserId == browser_id) {
          if (tab.tabURL.length > 0 && !BroURLIsBlank(tab.tabURL)) {
            [g_closed_tab_urls addObject:tab.tabURL];
            if (g_closed_tab_urls.count > kMaxClosedTabHistory) {
              [g_closed_tab_urls removeObjectAtIndex:0];
            }
          }
          break;
        }
      }
      [g_tab_bar removeTabWithBrowserId:browser_id];
    }

    // Remove and destroy the container view
    NSView* containerView = g_browser_views[@(browser_id)];
    if (containerView) {
      [containerView removeFromSuperview];
      [g_browser_views removeObjectForKey:@(browser_id)];
    }
    [g_blank_tab_ids removeObject:@(browser_id)];
  });
}

void OnActiveTabChanged(int browser_id) {
  BroRunOnMain(^{
    // Update tab bar
    if (g_tab_bar) {
      [g_tab_bar setActiveTab:browser_id];
    }

    UpdateTabContainerVisibility(browser_id);

    // The shell follows the active tab's viewport mode.
    UpdateWindowForViewportMode(TabIsMobile(browser_id), YES);
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
    // compiled-code caches between launches). BRO_USER_DATA_DIR overrides the
    // location so test harnesses can run isolated instances concurrently (the
    // profile directory holds the process-singleton lock, so two instances
    // sharing it cannot both launch).
    NSString* cachePath = nil;
    if (const char* data_dir = getenv("BRO_USER_DATA_DIR")) {
      if (data_dir[0] == '/') {
        cachePath = [NSString stringWithUTF8String:data_dir];
      }
    }
    if (!cachePath) {
      NSString* appSupport = NSSearchPathForDirectoriesInDomains(
          NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
      cachePath = [appSupport stringByAppendingPathComponent:@"Bro"];
    }
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

    // Pure black pre-load background (matches the per-browser settings) so
    // popups and navigations never flash a lighter rectangle over the glass.
    settings.background_color = CefColorSetARGB(255, 0, 0, 0);

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
