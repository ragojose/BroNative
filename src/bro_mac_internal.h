// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Private shared header for the bro_mac.mm split family (bro_mac.mm,
// bro_favicon.mm, bro_downloads.mm, bro_toolbar.mm, bro_closed_tabs.mm,
// bro_palette.mm, bro_tabstrip.mm). Declares the cross-file globals, the
// cross-file free functions, and the @class/@interface declarations that
// must be visible across the family. Not a public API -- nothing outside
// this file family should include it.

#ifndef BRO_MAC_INTERNAL_H_
#define BRO_MAC_INTERNAL_H_

#import <Cocoa/Cocoa.h>

#import "bro_geometry.h"

#include <string>

@class BroToolbar;
@class BroTabView;
@class BroTabBar;
@class BroHoverButton;
@class BroHoverHighlightGroup;
@class BroShimmerTextView;

// Layout/timing constants shared across the split family. Each file gets
// its own copy (harmless for compile-time constants); kWindowBorderAlpha is
// the one exception with a single non-static definition, below.
static const CGFloat kToolbarHeight = 52.0;
static const CGFloat kButtonSize = 28.0;
static const CGFloat kButtonSpacing = 4.0;
static const CGFloat kToolbarTrailingInset = 12.0;
// Radix's magnifier has 2pt more visible whitespace toward Downloads than
// the Download/Desktop pair. Move the complete control—not only its glyph—
// so its icon remains centered inside hover and focus feedback.
static const CGFloat kTabSearchOpticalOffsetX = 2.0;

// The trailing controls are indexed from the right: mobile = 0, desktop = 1,
// downloads = 2, search = 3. Keeping their x positions on one equation makes
// the 4pt rhythm survive every window and mobile-shell resize.
static inline CGFloat BroTrailingControlX(CGFloat toolbarWidth,
                                          NSUInteger indexFromRight) {
  return toolbarWidth - kToolbarTrailingInset - kButtonSize -
         indexFromRight * (kButtonSize + kButtonSpacing);
}
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
// Every tab-text state shares these metrics: inactive morph, active resting
// morph, and the editable address field. Keeping them tokenized prevents a
// tab switch from changing either font size or baseline geometry.
static const CGFloat kTabTextFontSize = 10.0;
static const CGFloat kTabTextFrameHeight = 18.0;
// A collapsed pill is exactly square.
static const CGFloat kTabPillSquareWidth = kTabPillHeight;
// A pinned inactive pill stays text-free but keeps separate favicon/select
// and trailing unpin targets.
static const CGFloat kPinnedTabPillWidth = 52.0;
// The "+" button is half the pill's size, centered on the same midline.
static const CGFloat kAddTabButtonSize = kTabPillHeight / 2.0;
static const CGFloat kTrafficLightInset = 100.0;
static const CGFloat kMobileViewportWidth = 390.0;
static const CGFloat kMobileViewportHeight = 844.0;  // matches CDP metrics
// Shell width while the window hugs the mobile viewport: the 390pt column
// plus bezels wide enough that the chrome row (~496pt minimum with the
// downloads button) still fits.
static const CGFloat kMobileShellWidth = 512.0;
static const NSTimeInterval kViewportAnimDuration = 0.28;
// Tab hover card: dwell time on a pill before the card appears (its width
// tracks the hovered pill's). The grace period keeps the card up after the
// mouse leaves the pill so it can travel onto the card's action buttons.
static const NSTimeInterval kHoverCardDelay = 1.0;
static const NSTimeInterval kHoverCardHideGrace = 0.3;
static const CGFloat kHoverCardButtonSize = 24.0;
// Hover/press icon feedback: the whole button scales about its center,
// animated by the shared 0.15s ease-out layer actions. Kept subtle so the
// chrome stays calm; skipped entirely under Reduce Motion.
static const CGFloat kIconHoverScale = 1.07;
static const CGFloat kIconPressScale = 0.95;
static const NSTimeInterval kCloseButtonFadeDuration = 0.15;
// Gap between tab pills in the strip.
static const CGFloat kTabGap = 8.0;
// A joined split pair overlaps by 1pt so the two 1pt borders coincide: the
// pair reads as one continuous pill with a single interior hairline.
static const CGFloat kSplitJoinedOverlap = 1.0;
// Divider drag clamps: neither pane may shrink past this share / width.
static const CGFloat kSplitRatioMin = 0.15;
static const CGFloat kSplitRatioMax = 0.85;
static const CGFloat kSplitPaneMinWidth = 120.0;

// What a blank tab is called everywhere it surfaces: pill label, hover card,
// accessibility label, and the window title AppKit shows in the Window menu.
static NSString* const kBroBlankTabTitle = @"New Tab";

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
// both `panel` and its owner button. See the definition in bro_palette.mm
// for the full contract.
extern id BroInstallOutsideDismissMonitor(NSView* panel,
                                           BOOL (^isVisible)(void),
                                           NSView* (^ownerButton)(void),
                                           void (^hide)(void));

// Fetches `urlString`'s favicon and hands the result to `applyImage`, but
// only if `stillCurrent` still says `generation` is current when the fetch
// completes. Shared by BroTabView and BroPaletteRow, which each bump their
// own generation counter before calling this (a slow response for an
// already-superseded favicon must not overwrite a newer one).
extern void BroFetchFaviconGuarded(NSString* urlString,
                                    NSUInteger generation,
                                    BOOL (^stillCurrent)(NSUInteger generation),
                                    void (^applyImage)(NSImage* image));

// Downloads popover: toggle shows or hides it; hide is safe to call any
// time. Defined with the popover class. The popover never opens while the
// list is empty — gate menu validation on BroHasRecentDownloads.
extern void BroHideDownloadsPopover(void);
extern void BroToggleDownloadsPopover(void);
extern BOOL BroHasRecentDownloads(void);

// Blank pages (and browsers with no committed URL yet) keep their opaque CEF
// view hidden so the black window backdrop shows through as the new-tab
// state, and never show the raw "about:blank" in the chrome.
extern BOOL BroURLIsBlank(NSString* url);

// Resolves user input into a loadable URL: safe schemes and about: pass
// through, a dotted word gets https://, anything else becomes a Google
// search URL. |query| must be trimmed; returns nil when empty. Defined in
// bro_toolbar.mm; shared with the command palette's fallback row.
extern NSString* BroResolveQueryToURL(NSString* query);

// Display-only host for a URL: the host with any leading "www." removed.
// Falls back to the raw string when the URL has no parseable host. Never used
// for navigation; BroTabView.tabURL keeps the canonical URL.
extern NSString* BroDisplayHostForURL(NSString* urlString);

// Animates the window between its desktop frame and a shell that hugs the
// mobile viewport, tracking the active tab's viewport mode. Stays in the hub
// (bro_mac.mm) -- one of the two functions every subsystem calls into.
extern void UpdateWindowForViewportMode(BOOL mobile, BOOL animate);
// Variant that runs |completion| once the layout change has settled (every
// path, including early returns, invokes it exactly once).
extern void UpdateWindowForViewportMode(BOOL mobile, BOOL animate,
                                        void (^completion)(void));

// Forward declaration of tab creation functions; implemented after
// BroWindow (hub).
extern void CreateNewBrowserTab(void);
extern void CreateNewBrowserTabWithURL(const std::string& url);

// Shared semantic hairline for emphasized controls and keyboard focus. It
// resolves with the current AppKit/glass appearance instead of freezing a
// dark-only RGB value.
extern NSColor* BroControlBorderColor(void);

// Shared semantic tint for the template globe shown while a tab has no
// fetched favicon.
extern NSColor* BroPlaceholderFaviconColor(void);

// True if the given tab has mobile emulation active.
extern BOOL TabIsMobile(int browser_id);

// Split screen: the tab shown beside the active one; -1 = no split. The
// active tab is always the left pane and keeps the address bar and chrome
// shortcuts; selecting the right pane's pill swaps it into the active slot.
// These stay in the hub (bro_mac.mm) -- BroTabBar orchestrates split via
// these calls without owning the state.
extern int g_split_browser_id;
extern BOOL SplitActive(void);
extern void ToggleSplitForTab(int browser_id);
extern void RefreshSplitPaneStyling(void);
extern void ClearSplit(void);
extern void JoinTabsInSplit(int dragged_id, int target_id);
extern NSUInteger BroTabStripIndex(int browser_id);

// Command palette (⌘K; ⇧⌘A and the tab strip's chevron open it scoped to
// tabs): toggle shows or hides the centered panel; hide is safe to call any
// time. Defined with the panel class in bro_palette.mm.
typedef NS_ENUM(NSInteger, BroPaletteScope) {
  BroPaletteScopeAll,   // tabs + history + commands + web-search fallback
  BroPaletteScopeTabs,  // open + recently closed tabs only
};
extern void ToggleCommandPalette(BroPaletteScope scope);
extern void HideCommandPalette(void);
// Releases the retained palette; called when the main window is torn down.
extern void TeardownCommandPalette(void);

// Implicit-animation actions so state changes (hover/focus/active) fade
// instead of snapping. Backing layers suppress implicit animations by
// default; installing explicit actions re-enables them for these keys.
extern NSDictionary* BroLayerTransitionActions(void);

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
// Optional shared hover preview. Grouped buttons keep pressed/selected
// feedback but let the group own hover fill and hover motion.
@property (nonatomic, weak) BroHoverHighlightGroup* highlightGroup;
// Canonical shortcut metadata for the native tooltip, VoiceOver help, and
// focused contextual activation. Global commands use matching NSMenuItems.
@property (nonatomic, copy) NSString* shortcutKeyEquivalent;
@property (nonatomic, assign) NSEventModifierFlags shortcutModifierMask;
// Used by compound controls to keep hover surfaces visible while keyboard
// focus moves through them and to track contextual shortcut targets.
@property (nonatomic, copy) void (^focusChangedHandler)(BroHoverButton* button,
                                                        BOOL focused);
@property (nonatomic, copy) void (^hoverChangedHandler)(BroHoverButton* button,
                                                        BOOL hovered);
- (void)configureActionLabel:(NSString*)label
               keyEquivalent:(NSString*)keyEquivalent
                modifierMask:(NSEventModifierFlags)modifierMask;
@end

// Shared shortcut formatting/matching keeps menu hints, tooltips, and
// contextual event routing in agreement.
extern NSString* BroShortcutDisplayString(NSString* keyEquivalent,
                                          NSEventModifierFlags modifierMask);
extern BOOL BroEventMatchesShortcut(NSEvent* event,
                                    NSString* keyEquivalent,
                                    NSEventModifierFlags modifierMask);

// Builds a dimmed, non-editable NSTextField used by the hover card, the
// downloads popover, and the tab search panel/rows.
extern NSTextField* BroHoverCardLabel(NSFont* font, CGFloat whiteAlpha);

#pragma mark - BroTabView

// NSTextField subclass that tells the toolbar when it gains focus, so the
// pill can swap from host-only display to the full editable URL.
@interface BroAddressField : NSTextField
@end

// One tab pill in the tab strip. Each pill permanently owns its address field;
// the active pill reveals it only while editing.
@interface BroTabView : NSView
@property (nonatomic, assign) int browserId;
// The tab bar remains the interaction owner even though pills live inside its
// scroll view's document view rather than as direct children.
@property (nonatomic, weak) BroTabBar* owningTabBar;
@property (nonatomic, strong) NSImageView* faviconView;
@property (nonatomic, strong) BroShimmerTextView* titleLabel;
// Each pill owns its editor for its entire lifetime. Only the active pill may
// reveal it, which avoids moving a live AppKit field editor between views.
@property (nonatomic, strong) BroAddressField* addressField;
@property (nonatomic, strong) BroHoverButton* closeButton;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL isLoading;
// NO on a lone tab: closing it would close the window, so the pill hides ✕.
@property (nonatomic, assign) BOOL closable;
// YES while the owned address field is being edited; keeps the focused
// border through hover/layout appearance refreshes.
@property (nonatomic, assign) BOOL editingAddress;
// YES once the pill is too narrow for text: favicon only, centered.
@property (nonatomic, assign) BOOL iconOnly;
// Pinned pills sit as compact favicon-only controls at the left edge of the
// strip, with a separate hover-revealed unpin action. The active pinned pill
// expands so the hosted address field stays usable; Cmd+W still closes it.
@property (nonatomic, assign) BOOL pinned;
// YES while this tab is the split screen's right pane; inactive pills get the
// active-ish border so both halves read as "on screen".
@property (nonatomic, assign) BOOL isSplitPane;
// While split, the two pane pills sit adjacent and read as one joined control
// (mirroring the panes below): 1 = left half of the pair (right corners
// squared), 2 = right half (left corners squared), 0 = normal lone pill.
@property (nonatomic, assign) NSInteger joinedSide;
// YES while a dragged pill hovers this one (drop would split the two tabs);
// the pill lights up as the drop target.
@property (nonatomic, assign) BOOL dropTarget;
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
// Setting kicks off an async fetch into faviconView; the URL is retained so
// a closing tab's favicon can follow it into the recently-closed list.
@property (nonatomic, copy) NSString* faviconURL;
- (void)setLoading:(BOOL)loading;
- (void)setTabURL:(NSString*)url;
- (void)focusAddressField;
- (void)finishAddressEditing;
@end

#pragma mark - BroTabBar

// The tab strip lives INSIDE the toolbar row: tab pills scroll horizontally,
// the active pill hosts the editable address field, the "+" trails the last
// pill until the pills overflow, and the search control stays pinned at the
// trailing edge.
@interface BroTabBar : NSView
@property (nonatomic, strong) NSMutableArray<BroTabView*>* tabs;
@property (nonatomic, strong) BroHoverButton* addTabButton;
// Chevron pinned at the strip's right edge; opens the tab search panel.
@property (nonatomic, strong) BroHoverButton* tabSearchButton;
@property (nonatomic, assign) int activeTabId;
- (void)addTabWithBrowserId:(int)browserId title:(NSString*)title;
- (void)removeTabWithBrowserId:(int)browserId;
- (void)setActiveTab:(int)browserId;
// The pill for a browser id, or nil if the tab is gone.
- (BroTabView*)tabWithBrowserId:(int)browserId;
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
// the card, and hides it on click/drag/close/switch/resize. Leaving the pill
// only schedules the hide (kHoverCardHideGrace) so the mouse can travel onto
// the card's buttons; the card reports its own hover to cancel/re-arm it.
- (void)tabHoverBegan:(BroTabView*)tab;
- (void)tabHoverEnded:(BroTabView*)tab;
- (void)cardHoverBegan;
- (void)cardHoverEnded;
- (void)tabFocusBegan:(BroTabView*)tab;
- (void)tabFocusEnded:(BroTabView*)tab;
- (void)hideHoverCard;
- (void)updateTabDescription:(int)browserId description:(NSString*)desc;
// Toggles the tab's pinned state, moving it across the pinned/unpinned
// boundary (pinned pills are a strict prefix of the strip).
- (void)togglePinForTab:(BroTabView*)tab;
// Splits the active tab with the next tab in strip order (wrapping); no-op
// on a lone tab. Shared by the active tab's hover-card split button and the
// Window menu item.
- (void)splitActiveTabWithNextTab;
// Moves the split pair's pills next to each other so they can render as one
// joined control; refreshes the joined styling either way.
- (void)ensureSplitPairAdjacent;
// Menu shortcuts act on the visible hover-card tab when there is one, keeping
// their target identical to the icon whose tooltip advertises the shortcut.
- (BOOL)performContextualPinShortcut;
- (BOOL)performContextualSplitShortcut;
@end

// The tab bar; nil before the window exists. Defined with BroTabBar.
extern BroTabBar* g_tab_bar;

#pragma mark - BroToolbar

@interface BroToolbar : NSView <NSTextFieldDelegate>
@property (nonatomic, strong) BroHoverButton* backButton;
@property (nonatomic, strong) BroHoverButton* forwardButton;
@property (nonatomic, strong) BroHoverButton* refreshButton;
@property (nonatomic, strong) BroHoverButton* desktopButton;
@property (nonatomic, strong) BroHoverButton* mobileButton;
@property (nonatomic, strong) BroHoverButton* downloadsButton;
@property (nonatomic, strong) BroHoverHighlightGroup* navigationHighlightGroup;
@property (nonatomic, strong) BroHoverHighlightGroup* trailingHighlightGroup;
- (void)addressFieldDidFocus:(BroAddressField*)field;
- (void)setViewportMode:(BOOL)mobile;
- (void)updateURL:(NSString*)url;
- (void)focusAddressField;
// Resolves |urlString| via BroResolveQueryToURL and loads it in the active
// browser; also used by the command palette's fallback row.
- (void)navigateToURL:(NSString*)urlString;
// Download started/finished nudge: reveals the hidden search + downloads
// icons briefly (they hide at rest and show on hover; the toolbar owns the
// shared hover zone). Called from bro_downloads.mm.
- (void)pulseDownloadsButton;
// Completes the four-control trailing cluster after BroTabBar exists.
- (void)registerTabSearchButton:(BroHoverButton*)button;
// Menu-action forwarders; called on g_toolbar from BroWindow/BroAppDelegate
// and the UI-update bridge functions.
- (void)goBack:(id)sender;
- (void)goForward:(id)sender;
- (void)refresh:(id)sender;
- (void)toggleDownloads:(id)sender;
- (void)selectDesktopMode:(id)sender;
- (void)selectMobileMode:(id)sender;
- (void)updateNavigationState:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
@end

// Handles ⌥⌘R only while the downloads popover has an unambiguous focused
// or hovered magnifier target. Defined in bro_downloads.mm.
extern BOOL BroPerformContextualDownloadsShortcut(NSEvent* event);

#endif  // BRO_MAC_INTERNAL_H_
