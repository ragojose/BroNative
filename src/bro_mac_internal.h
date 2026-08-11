// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Private shared header for the bro_mac.mm split family (bro_mac.mm,
// bro_favicon.mm, bro_downloads.mm, bro_toolbar.mm, bro_closed_tabs.mm,
// bro_tabsearch.mm, bro_tabstrip.mm). Declares the cross-file globals, the
// cross-file free functions, and the @class/@interface declarations that
// must be visible across the family. Not a public API -- nothing outside
// this file family should include it.

#ifndef BRO_MAC_INTERNAL_H_
#define BRO_MAC_INTERNAL_H_

#import <Cocoa/Cocoa.h>

@class BroToolbar;

// Window chrome: solid #000 backdrop with a #111 hairline frame. The hover
// card keeps its own lighter border (kWindowBorderAlpha over its gray fill).
extern const CGFloat kWindowBorderAlpha;

// UI font: bundled Geist (registered via ATSApplicationFontsPath), falling
// back to the system font if the resource is missing. SemiBold stands in for
// bold — Geist Bold reads too heavy at chrome sizes (11–14pt).
extern NSFont* BroUIFont(CGFloat size);
extern NSFont* BroUIFontBold(CGFloat size);

// The toolbar; nil before the window exists. Defined with BroToolbar.
extern BroToolbar* g_toolbar;

// The main window's browser container (overlay parent for transient
// overlays); nil before the window exists. Defined with BroWindow.
extern NSView* BroBrowserContainerView(void);

// Runs |block| synchronously if already on the main thread, otherwise
// dispatches it there. The CEF UI thread is the main thread here, so this
// only matters for calls arriving from a CEF worker/IO thread.
extern void BroRunOnMain(void (^block)(void));

// Installs a local mouse-down monitor that hides `panel` on any click outside
// both `panel` and its owner button. See bro_mac.mm's prior definition site
// for the full contract; behavior is unchanged by the move.
extern id BroInstallOutsideDismissMonitor(NSView* panel,
                                           BOOL (^isVisible)(void),
                                           NSView* (^ownerButton)(void),
                                           void (^hide)(void));

// Downloads popover: toggle shows or hides it; hide is safe to call any
// time. Defined with the popover class.
extern void BroHideDownloadsPopover(void);
extern void BroToggleDownloadsPopover(void);

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

// Builds a dimmed, non-editable NSTextField used by the hover card, the
// downloads popover, and the tab search panel/rows.
extern NSTextField* BroHoverCardLabel(NSFont* font, CGFloat whiteAlpha);

#pragma mark - BroToolbar

@interface BroToolbar : NSView <NSTextFieldDelegate>
@property (nonatomic, strong) BroHoverButton* backButton;
@property (nonatomic, strong) BroHoverButton* forwardButton;
@property (nonatomic, strong) BroHoverButton* refreshButton;
@property (nonatomic, strong) NSTextField* addressField;
@property (nonatomic, strong) BroHoverButton* desktopButton;
@property (nonatomic, strong) BroHoverButton* mobileButton;
@property (nonatomic, strong) BroHoverButton* downloadsButton;
@property (nonatomic, copy) NSString* fullURL;
- (void)addressFieldDidFocus;
- (void)setViewportMode:(BOOL)mobile;
- (void)updateURL:(NSString*)url;
- (void)focusAddressField;
@end

#endif  // BRO_MAC_INTERNAL_H_
