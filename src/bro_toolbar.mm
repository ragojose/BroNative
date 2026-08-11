// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "include/cef_browser.h"
#include "bro_handler.h"
#import "bro_mac_internal.h"
#import "radix_icons.h"

#pragma mark - BroToolbar

// g_toolbar is declared extern in bro_mac_internal.h.
BroToolbar* g_toolbar = nil;

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
    _addressField.font = BroUIFont(12.0);
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
    // Downloads sits left of the viewport radio group, set off by a wider
    // gap so it doesn't read as a third mode.
    rightX -= kButtonSize + kButtonSpacing + 8.0;
    _downloadsButton = [self createButtonWithFrame:NSMakeRect(rightX, y, kButtonSize, kButtonSize)
                                              icon:RadixIconDownload
                                            action:@selector(toggleDownloads:)
                                             label:@"Downloads"];
    _downloadsButton.autoresizingMask = NSViewMinXMargin;
    [self addSubview:_downloadsButton];
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
      // AppKit pins field-editor text to the top of its bounds, while the
      // settled URL is vertically centered by the text-field cell. Use the
      // settled URL's baseline for editing too, so focusing and typing never
      // makes the text jump.
      CGFloat textHeight =
          [self.addressField.cell cellSizeForBounds:self.addressField.bounds]
              .height;
      editor.textContainerInset = NSMakeSize(
          0.0, MAX(0.0, (self.addressField.bounds.size.height - textHeight) /
                            2.0));
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
  if (BroURLIsBlank(url)) {
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
