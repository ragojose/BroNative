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
#import "bro_updater.h"
#import "radix_icons.h"
#import "bro_mac_internal.h"
#import "bro_closed_tabs.h"
#import "bro_find.h"
#import "bro_history.h"
#import "bro_motion.h"
#import "bro_persist.h"

// Forward declarations
@class BroWindow;
@class BroToolbar;
@class BroTabBar;
@class BroTabView;

// Layout/timing constants shared across the split family (toolbar, tab strip,
// hover card, command palette, downloads popover) live in
// bro_mac_internal.h.

// BroUIFont/BroUIFontBold are declared in bro_mac_internal.h.
NSFont* BroUIFont(CGFloat size) {
  return [NSFont fontWithName:@"Geist-Regular" size:size]
             ?: [NSFont systemFontOfSize:size];
}

NSFont* BroUIFontBold(CGFloat size) {
  return [NSFont fontWithName:@"Geist-SemiBold" size:size]
             ?: [NSFont boldSystemFontOfSize:size];
}

// BroControlBorderColor is declared extern in bro_mac_internal.h.
NSColor* BroControlBorderColor(void) {
  return [NSColor separatorColor];
}

NSColor* BroPlaceholderFaviconColor(void) {
  return [NSColor tertiaryLabelColor];
}

// Global references
static BroWindow* g_main_window = nil;
// g_toolbar is declared extern in bro_mac_internal.h; defined in
// bro_toolbar.mm. g_tab_bar is declared extern there too.
BroTabBar* g_tab_bar = nil;

// Map browser IDs to their container views
static NSMutableDictionary<NSNumber*, NSView*>* g_browser_views = nil;

// Tabs currently on a blank page (about:blank or no committed URL yet). Their
// container stays hidden even while active so the unified shell shows through
// as the new-tab state.
static NSMutableSet<NSNumber*>* g_blank_tab_ids = nil;

// Tabs whose live container is dissolving into the glass backdrop. Membership
// owns the deferred detach; re-attaching a tab removes it so the stale
// animation completion becomes a no-op.
static NSMutableSet<NSNumber*>* g_fading_out_ids = nil;

// CEF's hosted IOSurface does not reliably inherit its container's group
// opacity. Page/glass dissolves therefore animate an AppKit-owned glass veil
// above it instead of attempting to fade the CEF view itself.
static NSView* g_glass_transition_overlay = nil;
static int g_glass_transition_token = 0;

// BroClosedTabEntry and the closed-tab history list live in
// bro_closed_tabs.mm, behind BroRecordClosedTab/BroClosedTabsList/
// BroClosedTabsCount/BroRemoveClosedTab/BroClearClosedTabs.

// Containers created for incoming popup browsers, keyed by popup ID. Entries
// are removed when the popup's browser is adopted as a tab, or on abort.
static NSMutableDictionary<NSNumber*, NSView*>* g_pending_popup_containers = nil;

// Blank tabs created by the shell should be ready for typing as soon as CEF
// adopts them. Track the exact container rather than a shared boolean: browser
// creation is asynchronous, and several tabs may be in flight at once.
static NSHashTable<NSView*>* g_pending_address_focus_containers = nil;

// Downloads: BroDownloadEntry, BroDownloadsList, the popover, and the
// bridge callbacks live in bro_downloads.mm. BroHideDownloadsPopover and
// BroToggleDownloadsPopover are declared extern in bro_mac_internal.h.

// Split screen: the tab shown beside the active one; -1 = no split. The
// active tab is always the left pane and keeps the address bar and chrome
// shortcuts; selecting the right pane's pill swaps it into the active slot.
// Helpers are implemented with the container layout code. g_split_browser_id
// and the split functions are declared extern in bro_mac_internal.h.
int g_split_browser_id = -1;
// Fraction of the browser area the left pane owns; the divider drags it.
static CGFloat g_split_ratio = 0.5;
// The balance the last split ended with; re-splitting starts from it instead
// of resetting to 50/50. Session-only.
static CGFloat g_last_split_ratio = 0.5;

// CreateNewBrowserTab(WithURL), ToggleCommandPalette, and HideCommandPalette
// are declared extern in bro_mac_internal.h.

// Transient overlays (the command palette, the downloads popover) must not
// outlive a command that changes what's underneath them -- otherwise they're
// left floating over content or chrome they no longer describe. Each overlay
// used to hand-roll its own dismissal at a handful of call sites and they
// drifted out of sync (see M1/L1 in the codebase audit); every command that
// changes page or layout state should dismiss through this one helper
// instead of picking and choosing which overlay to hide.
static void BroDismissTransientOverlays(void) {
  HideCommandPalette();
  BroHideDownloadsPopover();
}

// BroBrowserContainerView is declared extern in bro_mac_internal.h;
// implemented after BroWindow below.

// Reframes every per-tab container for its own viewport mode (mobile
// emulation is per-tab).
static void UpdateChromeLayout(void);

// UpdateWindowForViewportMode (both overloads) and BroURLIsBlank are
// declared extern in bro_mac_internal.h.

// Desktop frame to restore when leaving mobile layout; NSZeroRect = none
// saved. Saved only when empty and cleared only when a desktop restore
// completes, so interrupted toggle cycles never overwrite the original.
static NSRect g_saved_desktop_frame = NSZeroRect;
// Whether the shell currently hugs the mobile viewport (set at animation
// start, so re-entrant calls see consistent state).
static BOOL g_window_in_mobile_layout = NO;
// Stale-completion guard: a superseded animation must not restore masks.
static int g_viewport_anim_token = 0;
// True while the viewport toggle animation is in flight. Visibility updates
// arriving mid-animation (e.g. from the toggle's own deferred reload) are
// parked in g_visibility_update_pending and flushed by the completion so
// they can't snap the animating frames.
static BOOL g_viewport_animating = NO;
static BOOL g_visibility_update_pending = NO;

// True while screenshot mode (Cmd+S) is hiding the chrome. Declared up here
// (rather than with the rest of the feature, in the pragma mark below) so
// UpdateTabContainerVisibility's glass-backdrop check can read it -- that
// function is defined earlier in the file. See "#pragma mark - Screenshot
// Mode" for the toggle itself.
static BOOL g_screenshot_mode_active = NO;

// TabIsMobile is declared extern in bro_mac_internal.h.
BOOL TabIsMobile(int browser_id) {
  BroHandler* handler = BroHandler::GetInstance();
  return handler && handler->IsTabMobile(browser_id);
}

// kBroBlankTabTitle is declared in bro_mac_internal.h.

// BroURLIsBlank is declared extern in bro_mac_internal.h.
BOOL BroURLIsBlank(NSString* url) {
  return url.length == 0 || [url isEqualToString:@"about:blank"];
}

// BroDisplayHostForURL is declared extern in bro_mac_internal.h.
NSString* BroDisplayHostForURL(NSString* urlString) {
  NSString* host = [NSURL URLWithString:urlString ?: @""].host;
  if (host.length == 0) {
    return urlString ?: @"";
  }
  if (host.length > 4 && [host.lowercaseString hasPrefix:@"www."]) {
    return [host substringFromIndex:4];
  }
  return host;
}

// BroLayerTransitionActions is declared extern in bro_mac_internal.h.
NSDictionary* BroLayerTransitionActions(void) {
  NSMutableDictionary* actions = [NSMutableDictionary dictionary];
  for (NSString* key in
       @[ @"borderColor", @"backgroundColor", @"borderWidth" ]) {
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:key];
    fade.duration = 0.15;
    fade.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    actions[key] = fade;
  }
  actions[@"transform"] =
      BroSpringForKeyPath(@"transform", BroSpringInteractive);
  return actions;
}

// BroHoverButton, BroTabView, BroTabHoverCard, and BroTabBar's
// implementations live in bro_tabstrip.mm.

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

// AppKit owns the outer shell shape. Cache its resolved radius as the root of
// the app-wide corner hierarchy before constructing any nested chrome views.
static CGFloat g_shell_corner_radius = BroNestedCornerRadius(
    kShellCornerRadiusFallback, kShellCornerRadiusReduction);

CGFloat BroShellCornerRadius(void) {
  return g_shell_corner_radius;
}

static CGFloat BroResolveShellCornerRadius(NSWindow* window) {
  NSView* frameView = window.contentView.superview;  // NSThemeFrame
  if ([frameView respondsToSelector:@selector(cornerRadius)]) {
    CGFloat r = [[frameView valueForKey:@"cornerRadius"] doubleValue];
    if (r > 0.5) {
      return BroNestedCornerRadius(r, kShellCornerRadiusReduction);
    }
  }
  return BroNestedCornerRadius(kShellCornerRadiusFallback,
                               kShellCornerRadiusReduction);
}

// A compact dissolve keeps tab switching responsive while leaving enough
// time for the AppKit-owned veil to hide CEF's non-animatable IOSurface.
static const CFTimeInterval kGlassBackdropFadeDuration = 0.18;
static const CFTimeInterval kGlassPageFadeInDuration = 0.22;
static const CFTimeInterval kGlassHandoffDelay = 0.01;

// A pronounced ease-in-out keeps the page/shell handoff gentle at both ends
// while still moving decisively through the middle of the dissolve.
static CAMediaTimingFunction* BroGlassTransitionTimingFunction(void) {
  return [CAMediaTimingFunction functionWithControlPoints:0.65
                                                       :0.0
                                                       :0.35
                                                       :1.0];
}

// Coming out of glass stays slightly gentler so an incoming CEF frame joins
// the shortened dissolve instead of snapping in through the middle.
static CAMediaTimingFunction* BroPageFadeInTimingFunction(void) {
  return [CAMediaTimingFunction functionWithControlPoints:0.37
                                                       :0.0
                                                       :0.63
                                                       :1.0];
}

// Returns a live copy of the shell material above the browser area. Reusing
// an in-flight veil lets a rapid reversal retarget its current presentation
// instead of replacing it with a differently composed frame.
static NSView* BroCreateGlassTransitionOverlay(NSView* parent,
                                               CGFloat initialAlpha) {
  if (!parent) {
    return nil;
  }
  if (g_glass_transition_overlay.superview == parent) {
    return g_glass_transition_overlay;
  }
  [g_glass_transition_overlay removeFromSuperview];

  NSView* surface = [[NSView alloc] initWithFrame:parent.bounds];
  surface.alphaValue = initialAlpha;
  surface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  BroInstallShellSurface(surface, 0.0);
  [parent addSubview:surface positioned:NSWindowAbove relativeTo:nil];
  g_glass_transition_overlay = surface;
  return surface;
}

@interface BroWindow : NSWindow {
  BOOL _glassBackdropVisible;
}
@property (nonatomic, strong) NSView* browserContainer;
@property (nonatomic, strong) BroToolbar* navToolbar;
@property (nonatomic, strong) BroTabBar* tabBar;
@property (nonatomic, strong) NSView* shellSurface;
@property (nonatomic, strong) NSView* borderOverlay;
- (BOOL)glassBackdropVisible;
- (void)setGlassBackdropVisible:(BOOL)visible;
@end

NSView* BroBrowserContainerView(void) {
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
    // The window stays non-opaque with a clear background so the rounded
    // corners composite cleanly and the shell blur can sample behind the
    // window. The transparent titlebar keeps the traffic lights inline.
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

    NSView* content = [[NSView alloc] initWithFrame:frame];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [NSColor clearColor].CGColor;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.contentView = content;
    g_shell_corner_radius = BroResolveShellCornerRadius(self);

    // A single stable shell-wide blur removes the material boundary at the
    // page edge without stretching Liquid Glass lensing across the content
    // area. Opaque CEF pages are composited above it in the browser area.
    NSView* shellSurface = [[NSView alloc] initWithFrame:frame];
    shellSurface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSView* shellContent =
        BroInstallShellSurface(shellSurface, BroShellCornerRadius());
    [content addSubview:shellSurface];
    _shellSurface = shellSurface;

    // Single chrome row at the very top; its content is inset past the
    // traffic lights.
    CGFloat toolbarY = frame.size.height - kToolbarHeight;
    _navToolbar = [[BroToolbar alloc]
        initWithFrame:NSMakeRect(0, toolbarY, frame.size.width, kToolbarHeight)];
    [shellContent addSubview:_navToolbar];
    g_toolbar = _navToolbar;

    // Tab strip inline in the toolbar row: after the nav buttons, before the
    // right-aligned viewport toggles.
    CGFloat stripX = kTrafficLightInset + 3 * (kButtonSize + kButtonSpacing) + 8.0;
    // The strip's right edge (where its pinned search button sits) keeps the
    // shared button rhythm, with a small optical correction for the
    // magnifier artwork. The complete control moves so its glyph stays
    // centered inside hover/focus feedback.
    CGFloat stripRight =
        BroTrailingControlX(frame.size.width, 3) + kButtonSize +
        kTabSearchOpticalOffsetX;
    _tabBar = [[BroTabBar alloc]
        initWithFrame:NSMakeRect(stripX, 0, stripRight - stripX, kToolbarHeight)];
    [_navToolbar addSubview:_tabBar];
    g_tab_bar = _tabBar;
    [_navToolbar registerTabSearchButton:_tabBar.tabSearchButton];
    // The toolbar's search/downloads reveal zone spans a tab-bar subview, so
    // recompute it now that the tab bar exists.
    [_navToolbar updateTrackingAreas];

    // Create container for browser views (below chrome)
    _browserContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, toolbarY)];
    _browserContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:_browserContainer];

    // Hairline frame on top of everything (added last so it draws above the
    // CEF child views).
    BroWindowBorderView* border = [[BroWindowBorderView alloc] initWithFrame:frame];
    border.wantsLayer = YES;
    border.layer.borderWidth = kBroGlassBorderWidth;
    border.layer.borderColor = BroGlassBorderColor().CGColor;
    border.layer.cornerRadius = BroShellCornerRadius();
    border.layer.cornerCurve = kCACornerCurveContinuous;
    border.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:border];
    _borderOverlay = border;

    // Initialize browser views dictionary
    g_browser_views = [NSMutableDictionary dictionary];
    g_blank_tab_ids = [NSMutableSet set];
    g_pending_address_focus_containers = [NSHashTable weakObjectsHashTable];
    g_fading_out_ids = [NSMutableSet set];
    // Closed-tab history lazily initializes itself on first use.

    // Keep the Tab-key loop current as pills and buttons come and go.
    self.autorecalculatesKeyViewLoop = YES;

    // Center the window
    [self center];

    // Set minimum size (wide enough for the pill + right-side toggles)
    self.minSize = NSMakeSize(760, 400);
  }
  return self;
}

// Tracks whether the shell is exposed by a blank tab. The material itself is
// always present now; only the opaque CEF page and its matching glass veil
// transition above it.
- (BOOL)glassBackdropVisible {
  return _glassBackdropVisible;
}

- (void)setGlassBackdropVisible:(BOOL)visible {
  _glassBackdropVisible = visible;
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

// SplitActive and BroTabStripIndex are declared extern in
// bro_mac_internal.h.
BOOL SplitActive(void) {
  return g_split_browser_id >= 0 &&
         g_browser_views[@(g_split_browser_id)] != nil;
}

// Strip index of a tab's pill; NSNotFound once the pill is gone.
NSUInteger BroTabStripIndex(int browser_id) {
  NSArray<BroTabView*>* tabs = g_tab_bar.tabs;
  for (NSUInteger i = 0; i < tabs.count; i++) {
    if (tabs[i].browserId == browser_id) {
      return i;
    }
  }
  return NSNotFound;
}

// The divider's x for a given browser-area width: the dragged ratio, kept
// far enough from the edges that neither pane collapses.
static CGFloat SplitDividerX(CGFloat totalWidth) {
  CGFloat x = floor(totalWidth * g_split_ratio);
  if (totalWidth < 2.0 * kSplitPaneMinWidth) {
    return floor(totalWidth / 2.0);
  }
  return MAX(kSplitPaneMinWidth, MIN(totalWidth - kSplitPaneMinWidth, x));
}

#pragma mark - BroSplitDivider

// The boundary between the split halves: a hairline with a centered grip
// knob, in a 9pt-wide grab strip floating above both panes. Dragging it
// re-balances the split (updates g_split_ratio and reframes the panes live).
static const CGFloat kSplitDividerGrabWidth = 9.0;
static BOOL g_split_divider_dragging = NO;

@interface BroSplitDivider : NSView
@end

@implementation BroSplitDivider {
  NSView* line_;
  NSView* grip_;
  BOOL hovered_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    line_ = [[NSView alloc]
        initWithFrame:NSMakeRect((kSplitDividerGrabWidth - 1.0) / 2.0, 0, 1.0,
                                 frame.size.height)];
    line_.wantsLayer = YES;
    line_.layer.backgroundColor = BroControlBorderColor().CGColor;
    line_.layer.actions = BroLayerTransitionActions();
    line_.autoresizingMask = NSViewHeightSizable;
    [self addSubview:line_];

    // The grip: a small rounded bar centered on the line, the visual
    // affordance that the boundary is draggable.
    grip_ = [[NSView alloc]
        initWithFrame:NSMakeRect((kSplitDividerGrabWidth - 4.0) / 2.0,
                                 (frame.size.height - 44.0) / 2.0, 4.0, 44.0)];
    grip_.wantsLayer = YES;
    grip_.layer.cornerRadius = BroCapsuleCornerRadius(NSWidth(grip_.frame));
    grip_.layer.backgroundColor =
        [[NSColor labelColor] colorWithAlphaComponent:0.4].CGColor;
    grip_.layer.actions = BroLayerTransitionActions();
    grip_.autoresizingMask = NSViewMinYMargin | NSViewMaxYMargin;
    [self addSubview:grip_];

    // Hover feedback: the resting divider is a #111 hairline that all but
    // vanishes against dark page content, so brighten it under the mouse to
    // advertise the drag affordance.
    [self addTrackingArea:[[NSTrackingArea alloc]
                              initWithRect:NSZeroRect
                                   options:NSTrackingMouseEnteredAndExited |
                                           NSTrackingActiveInKeyWindow |
                                           NSTrackingInVisibleRect
                                     owner:self
                                  userInfo:nil]];

    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilitySplitterRole;
    self.accessibilityLabel = @"Split screen divider";
  }
  return self;
}

// Lit while hovered or mid-drag (the mouse can leave the 9pt strip during a
// drag without ending it).
- (void)updateHighlight {
  BOOL lit = hovered_ || g_split_divider_dragging;
  line_.layer.backgroundColor =
      lit ? [[NSColor labelColor] colorWithAlphaComponent:0.25].CGColor
          : BroControlBorderColor().CGColor;
  grip_.layer.backgroundColor =
      [[NSColor labelColor] colorWithAlphaComponent:lit ? 0.7 : 0.4].CGColor;
}

- (void)mouseEntered:(NSEvent*)event {
  hovered_ = YES;
  [self updateHighlight];
}

- (void)mouseExited:(NSEvent*)event {
  hovered_ = NO;
  [self updateHighlight];
}

// The divider sits in the full-size-content title-bar-free window; without
// this a drag would move the window instead of the boundary.
- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:[NSCursor resizeLeftRightCursor]];
}

- (void)mouseDown:(NSEvent*)event {
  // Double-click re-centers the split; no drag follows, so skip the drag
  // state and cursor push entirely.
  if (event.clickCount == 2) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
      ctx.duration = 0.18;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      ctx.allowsImplicitAnimation = YES;
      g_split_ratio = 0.5;
      UpdateChromeLayout();
    } completionHandler:nil];
    return;
  }
  g_split_divider_dragging = YES;
  [self updateHighlight];
  [[NSCursor resizeLeftRightCursor] push];
}

- (void)mouseDragged:(NSEvent*)event {
  NSView* parent = self.superview;
  CGFloat width = NSWidth(parent.bounds);
  if (!SplitActive() || width <= 0) {
    return;
  }
  [[NSCursor resizeLeftRightCursor] set];
  NSPoint p = [parent convertPoint:event.locationInWindow fromView:nil];
  g_split_ratio = MAX(kSplitRatioMin, MIN(kSplitRatioMax, p.x / width));
  UpdateChromeLayout();
}

- (void)mouseUp:(NSEvent*)event {
  g_split_divider_dragging = NO;
  [self updateHighlight];
  [NSCursor pop];
}

@end

static BroSplitDivider* g_split_divider = nil;

static void UpdateSplitDivider(void) {
  NSView* parent = g_main_window.browserContainer;
  if (!parent) {
    return;
  }
  if (!g_split_divider) {
    g_split_divider = [[BroSplitDivider alloc]
        initWithFrame:NSMakeRect(0, 0, kSplitDividerGrabWidth,
                                 NSHeight(parent.bounds))];
  }
  // The divider must stack above both CEF pane views to catch the mouse;
  // containers re-attach above it, so re-add last — except mid-drag, when
  // tearing the view out from under its own mouse tracking would end it.
  if (g_split_divider.superview != parent ||
      (!g_split_divider_dragging &&
       parent.subviews.lastObject != g_split_divider)) {
    [g_split_divider removeFromSuperview];
    [parent addSubview:g_split_divider];
  }
  NSRect bounds = parent.bounds;
  g_split_divider.frame = NSMakeRect(
      SplitDividerX(bounds.size.width) - (kSplitDividerGrabWidth - 1.0) / 2.0,
      0, kSplitDividerGrabWidth, bounds.size.height);
  g_split_divider.autoresizingMask =
      NSViewMinXMargin | NSViewMaxXMargin | NSViewHeightSizable;
  g_split_divider.hidden = !SplitActive();
  [g_split_divider.window invalidateCursorRectsForView:g_split_divider];
}

// Frames a tab container for its role: full-bleed (or the centered mobile
// column) normally; half the browser area while split screen is active, with
// a 2pt gutter. Panes mirror the tab strip: the earlier pill is the left
// half, so activating the other pane never makes the pages swap sides. A
// mobile-emulated tab centers its 390pt column within whatever region it got.
static void ApplyFrameForTabContainer(NSView* container, int browser_id) {
  BroHandler* handler = BroHandler::GetInstance();
  int active_id = handler ? handler->GetActiveBrowserId() : -1;
  if (!SplitActive() ||
      (browser_id != active_id && browser_id != g_split_browser_id)) {
    ApplyViewportFrameToContainer(container, TabIsMobile(browser_id));
    return;
  }
  NSRect bounds = g_main_window.browserContainer.bounds;
  CGFloat split_x = SplitDividerX(bounds.size.width);
  int other_id = (browser_id == active_id) ? g_split_browser_id : active_id;
  NSUInteger mine = BroTabStripIndex(browser_id);
  NSUInteger theirs = BroTabStripIndex(other_id);
  BOOL left = (mine != NSNotFound && theirs != NSNotFound)
                  ? mine < theirs
                  : (browser_id == active_id);
  NSRect region =
      left ? NSMakeRect(0, 0, split_x - 1.0, bounds.size.height)
           : NSMakeRect(split_x + 1.0, 0, bounds.size.width - split_x - 1.0,
                        bounds.size.height);
  if (TabIsMobile(browser_id)) {
    CGFloat width = MIN(kMobileViewportWidth, region.size.width);
    region.origin.x += (region.size.width - width) / 2.0;
    region.size.width = width;
    container.frame = region;
    container.autoresizingMask =
        NSViewMinXMargin | NSViewMaxXMargin | NSViewHeightSizable;
    return;
  }
  container.frame = region;
  // Both halves and their margins scale by the same factor during a live
  // resize, preserving the 50/50 split until UpdateChromeLayout re-derives
  // exact frames.
  container.autoresizingMask =
      left ? (NSViewWidthSizable | NSViewMaxXMargin | NSViewHeightSizable)
           : (NSViewMinXMargin | NSViewWidthSizable | NSViewHeightSizable);
}

// Reflects the current split panes into the pill styling: the right pane gets
// the active-ish border (BroTabView.isSplitPane), and when the pair's pills
// are adjacent they render as one joined control (BroTabView.joinedSide)
// mirroring the panes below. Declared extern in bro_mac_internal.h.
void RefreshSplitPaneStyling(void) {
  BOOL active = SplitActive();
  for (BroTabView* tab in g_tab_bar.tabs) {
    tab.isSplitPane = active && tab.browserId == g_split_browser_id;
    tab.joinedSide = 0;
  }
  if (!active) {
    return;
  }
  BroHandler* handler = BroHandler::GetInstance();
  int active_id = handler ? handler->GetActiveBrowserId() : -1;
  NSUInteger ai = BroTabStripIndex(active_id);
  NSUInteger si = BroTabStripIndex(g_split_browser_id);
  if (ai == NSNotFound || si == NSNotFound ||
      (ai > si ? ai - si : si - ai) != 1) {
    return;
  }
  g_tab_bar.tabs[MIN(ai, si)].joinedSide = 1;
  g_tab_bar.tabs[MAX(ai, si)].joinedSide = 2;
}

// Ends the split and forgets its drag-adjusted balance. Declared extern in
// bro_mac_internal.h.
void ClearSplit(void) {
  g_split_browser_id = -1;
  g_last_split_ratio = g_split_ratio;
  g_split_ratio = 0.5;
  RefreshSplitPaneStyling();
}

// Drops the split when it stops making sense: its tab was closed, or the
// split tab was promoted to active without going through the pane swap (e.g.
// the handler picked it after the active tab closed).
static void ValidateSplitState(int active_browser_id) {
  if (g_split_browser_id < 0) {
    return;
  }
  if (g_split_browser_id == active_browser_id ||
      g_browser_views[@(g_split_browser_id)] == nil) {
    ClearSplit();
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
  browserContainer.wantsLayer = YES;
  browserContainer.layer.backgroundColor = [NSColor blackColor].CGColor;
  ApplyViewportFrameToContainer(browserContainer, NO);
  browserContainer.hidden = YES;  // Will be shown when tab is activated
  [g_main_window.browserContainer addSubview:browserContainer];
  return browserContainer;
}

// True while the whole window is occluded (miniaturized or fully covered);
// every tab counts as hidden so even the active one throttles.
static BOOL g_window_occluded = NO;

// Central visibility rule: only the active tab's container is visible, and
// not even that one while the tab is blank (the shell surface is the new-tab
// state). Hiding the container NSView is not
// enough for Chromium's occlusion tracking in windowed CEF (measured:
// background tabs kept rendering rAF at ~45fps and timers at ~4.5Hz), so
// hidden containers are detached from the window entirely —
// viewDidMoveToWindow(nil) is the signal the render widget host actually
// honors (measured: rAF frozen, timers at 1Hz).
static void UpdateTabContainerVisibility(int active_browser_id) {
  // Mid-animation attach/detach would snap the animating frames (the toggle's
  // own deferred reload fires OnTabURLChanged); park it for the completion.
  if (g_viewport_animating) {
    g_visibility_update_pending = YES;
    return;
  }
  BroHandler* handler = BroHandler::GetInstance();
  ValidateSplitState(active_browser_id);
  NSView* parent = g_main_window.browserContainer;
  if (BroMotionReduced() && g_glass_transition_overlay) {
    ++g_glass_transition_token;
    [g_glass_transition_overlay removeFromSuperview];
    g_glass_transition_overlay = nil;
    [g_fading_out_ids removeAllObjects];
  }
  // Use the full-browser veil only when every visible pane is blank. A mixed
  // split exposes the same shell in its blank pane without covering the loaded
  // partner. With no active tab there is no page transition to animate.
  BOOL activeBlank = [g_blank_tab_ids containsObject:@(active_browser_id)];
  BOOL partnerBlank =
      !SplitActive() || [g_blank_tab_ids containsObject:@(g_split_browser_id)];
  // Screenshot mode forces the glass on unconditionally: the browser
  // container sits inset from the window edge there, exposing the same stable
  // shell around it regardless of whether the page itself is blank.
  BOOL wantsGlass = g_screenshot_mode_active || (activeBlank && partnerBlank);
  BOOL glassWasVisible = [g_main_window glassBackdropVisible];
  for (NSNumber* key in g_browser_views) {
    // Split screen widens the visible set to both panes; each stays attached
    // and unthrottled (SetBrowserHidden(false)) while on screen.
    BOOL visible = key.intValue == active_browser_id ||
                   (SplitActive() && key.intValue == g_split_browser_id);
    BOOL hidden = !visible || [g_blank_tab_ids containsObject:key];
    NSView* container = g_browser_views[key];
    BOOL detached = hidden || g_window_occluded;
    if (detached) {
      BOOL wasOnScreen = container.superview == parent && !container.hidden;
      BOOL shouldFadeOut = wantsGlass && wasOnScreen && !g_window_occluded &&
                           !BroMotionReduced();
      if (shouldFadeOut) {
        if (![g_fading_out_ids containsObject:key] ||
            !g_glass_transition_overlay) {
          [g_fading_out_ids addObject:key];
          NSView* glassOverlay =
              BroCreateGlassTransitionOverlay(parent, 0.0);
          int transitionToken = ++g_glass_transition_token;
          [NSAnimationContext
              runAnimationGroup:^(NSAnimationContext* ctx) {
                ctx.duration = kGlassBackdropFadeDuration;
                ctx.timingFunction = BroGlassTransitionTimingFunction();
                glassOverlay.animator.alphaValue = 1.0;
              }
              completionHandler:^{
                if (transitionToken != g_glass_transition_token ||
                    g_glass_transition_overlay != glassOverlay) {
                  return;
                }
                for (NSNumber* fadingKey in g_fading_out_ids.allObjects) {
                  NSView* fadingContainer = g_browser_views[fadingKey];
                  [fadingContainer removeFromSuperview];
                  fadingContainer.hidden = YES;
                  fadingContainer.alphaValue = 1.0;
                  BroHandler* currentHandler = BroHandler::GetInstance();
                  if (currentHandler) {
                    currentHandler->SetBrowserHidden(fadingKey.intValue, true);
                  }
                }
                [g_fading_out_ids removeAllObjects];
                // Keep the finished veil just long enough for the CEF detach
                // to commit; the shell below is already the matching material.
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(kGlassHandoffDelay * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                      if (transitionToken != g_glass_transition_token ||
                          g_glass_transition_overlay != glassOverlay) {
                        return;
                      }
                      [glassOverlay removeFromSuperview];
                      g_glass_transition_overlay = nil;
                    });
              }];
        }
      } else {
        // g_browser_views keeps the container (and the CEF view inside it)
        // alive while it is out of the view hierarchy.
        [g_fading_out_ids removeObject:key];
        if (container.superview) {
          [container removeFromSuperview];
        }
        container.hidden = YES;
        container.alphaValue = 1.0;
        if (handler) {
          handler->SetBrowserHidden(key.intValue, true);
        }
      }
    } else {
      [g_fading_out_ids removeObject:key];
      BOOL wasDetached = container.superview != parent;
      BOOL hasTransitionVeil =
          g_glass_transition_overlay.superview == parent;
      BOOL shouldFadeIn =
          !wantsGlass && !BroMotionReduced() &&
          ((glassWasVisible && wasDetached) || hasTransitionVeil);
      NSView* revealOverlay =
          shouldFadeIn ? BroCreateGlassTransitionOverlay(parent, 1.0) : nil;
      container.alphaValue = 1.0;
      if (parent && wasDetached) {
        if (revealOverlay) {
          [parent addSubview:container
                   positioned:NSWindowBelow
                   relativeTo:revealOverlay];
        } else {
          [parent addSubview:container];
        }
        ApplyFrameForTabContainer(container, key.intValue);
      }
      container.hidden = NO;
      if (revealOverlay) {
        int transitionToken = ++g_glass_transition_token;
        [NSAnimationContext
            runAnimationGroup:^(NSAnimationContext* ctx) {
              ctx.duration = kGlassPageFadeInDuration;
              ctx.timingFunction = BroPageFadeInTimingFunction();
              revealOverlay.animator.alphaValue = 0.0;
            }
            completionHandler:^{
              if (transitionToken != g_glass_transition_token ||
                  g_glass_transition_overlay != revealOverlay) {
                return;
              }
              [revealOverlay removeFromSuperview];
              g_glass_transition_overlay = nil;
            }];
      }
      if (handler) {
        handler->SetBrowserHidden(key.intValue, false);
      }
    }
  }
  UpdateSplitDivider();
  [g_main_window setGlassBackdropVisible:wantsGlass];
}

static void UpdateChromeLayout(void) {
  if (!g_main_window || !g_main_window.browserContainer) {
    return;
  }
  for (NSNumber* key in g_browser_views) {
    // Detached (throttled) containers get their frame on re-attach in
    // UpdateTabContainerVisibility; re-framing them here is wasted work.
    if (!g_browser_views[key].superview) {
      continue;
    }
    ApplyFrameForTabContainer(g_browser_views[key], key.intValue);
  }
  UpdateSplitDivider();
}

// Resizes the shell to hug the mobile viewport (or back to the saved desktop
// frame), animating the window and the active tab's container as one motion.
// Declared extern in bro_mac_internal.h.
void UpdateWindowForViewportMode(BOOL mobile, BOOL animate) {
  UpdateWindowForViewportMode(mobile, animate, nil);
}

void UpdateWindowForViewportMode(BOOL mobile, BOOL animate,
                                 void (^completion)(void)) {
  if (!g_main_window) {
    if (completion) {
      completion();
    }
    return;
  }
  // In native fullscreen the shell can't hug the viewport; keep the current
  // centered-column behavior. windowDidExitFullScreen: re-syncs afterwards.
  if ((g_main_window.styleMask & NSWindowStyleMaskFullScreen) != 0) {
    UpdateChromeLayout();
    if (completion) {
      completion();
    }
    return;
  }
  if (mobile == g_window_in_mobile_layout) {
    UpdateChromeLayout();
    if (completion) {
      completion();
    }
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
  if (!mobile && SplitActive()) {
    // The active container only owns one half while split (which half follows
    // strip order); finish()'s UpdateChromeLayout re-derives both panes
    // exactly.
    CGFloat splitX = SplitDividerX(contentWidth);
    BroHandler* h = BroHandler::GetInstance();
    int active = h ? h->GetActiveBrowserId() : -1;
    NSUInteger mine = BroTabStripIndex(active);
    NSUInteger theirs = BroTabStripIndex(g_split_browser_id);
    BOOL activeLeft = mine == NSNotFound || theirs == NSNotFound || mine < theirs;
    containerTarget.origin.x = activeLeft ? 0 : splitX + 1.0;
    containerTarget.size.width =
        activeLeft ? splitX - 1.0 : contentWidth - splitX - 1.0;
  }

  BroHandler* handler = BroHandler::GetInstance();
  int activeId = handler ? handler->GetActiveBrowserId() : -1;
  NSView* activeContainer =
      (activeId >= 0) ? g_browser_views[@(activeId)] : nil;
  NSView* cefView = activeContainer.subviews.firstObject;

  void (^finish)(void) = ^{
    // A newer toggle owns the layout now; let its completion do the work
    // (and its reload — dropping this completion is what coalesces rapid
    // toggles into a single reload with the final state).
    if (token != g_viewport_anim_token || !g_main_window) {
      return;
    }
    g_viewport_animating = NO;
    UpdateChromeLayout();  // exact frames + proper autoresizing masks
    cefView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    cefView.frame = activeContainer.bounds;
    if (!mobile) {
      g_main_window.minSize = NSMakeSize(760, 400);
      g_saved_desktop_frame = NSZeroRect;
    }
    if (g_visibility_update_pending) {
      g_visibility_update_pending = NO;
      BroHandler* h = BroHandler::GetInstance();
      if (h) {
        UpdateTabContainerVisibility(h->GetActiveBrowserId());
      }
    }
    if (completion) {
      completion();
    }
  };

  if (!animate) {
    [g_main_window setFrame:target display:YES];
    finish();
    return;
  }

  // Freeze autoresizing on the visible container so the window animation's
  // per-tick autoresize doesn't fight the animator; finish() restores the
  // proper mask via ApplyViewportFrameToContainer. The CEF view inside is
  // frozen too and snapped straight to its final size: resizing the render
  // widget every animation tick forces Chromium to re-layout and allocate a
  // new compositor surface ~17 times per toggle, which is what made the
  // transition stutter. The animating container just clips/reveals it.
  activeContainer.wantsLayer = YES;
  activeContainer.layer.masksToBounds = YES;
  cefView.autoresizingMask = NSViewNotSizable;
  cefView.frame = NSMakeRect(0, 0, containerTarget.size.width,
                             containerTarget.size.height);
  activeContainer.autoresizingMask = NSViewNotSizable;
  g_viewport_animating = YES;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = kViewportAnimDuration;
        ctx.timingFunction = [CAMediaTimingFunction
            functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [[g_main_window animator] setFrame:target display:NO];
        [[activeContainer animator] setFrame:containerTarget];
      }
      completionHandler:finish];
}

#pragma mark - Screenshot Mode

// Cmd+S (View menu) hides the toolbar -- and the tab strip nested inside it,
// since BroTabBar is one of its subviews -- and the traffic lights, leaving
// an Arc-style frame: the page sits as a rounded card inset by
// kScreenshotModeGutter on all four sides, with the window's existing glass
// (the same material the chrome row already wears -- setGlassBackdropVisible:
// below) showing through the gutter, and the existing hairline
// (BroWindowBorderView) still tracing the true window edge outside all of
// it. The active tab's container(s) already fill 100% of browserContainer's
// bounds in every mode -- desktop, mobile, split -- so animating just
// browserContainer's own frame is enough: AppKit's autoresizing reflows the
// CEF containers, their CEF child views, and the split divider at every
// tick, the same way applyTabLayout: leans on autoresizing instead of
// hand-reframing each child (bro_tabstrip.mm). g_screenshot_mode_active
// itself lives up with the other early globals -- UpdateTabContainerVisibility
// reads it and is defined earlier in this file.
static const CGFloat kScreenshotModeGutter = 8.0;
static id g_screenshot_esc_monitor = nil;
// Traffic-light visibility as it was the moment screenshot mode was entered;
// restored exactly rather than assumed, since fullscreen and other states can
// already have them hidden independently.
static BOOL g_screenshot_saved_close_hidden = NO;
static BOOL g_screenshot_saved_miniaturize_hidden = NO;
static BOOL g_screenshot_saved_zoom_hidden = NO;

static void RemoveScreenshotEscMonitor(void) {
  if (g_screenshot_esc_monitor) {
    [NSEvent removeMonitor:g_screenshot_esc_monitor];
    g_screenshot_esc_monitor = nil;
  }
}

// Toggles the mode; shared by the View menu item and by newTab:/
// focusAddressBar:, which exit the mode before doing their own thing --
// both need the chrome back to be usable. Declared static; BroAppDelegate's
// toggleScreenshotMode: is the entry point from outside this pragma mark.
static void ToggleScreenshotMode(void) {
  if (!g_main_window) {
    return;
  }
  BroDismissTransientOverlays();
  // Releases focus from an editing address field or tab search field --
  // hidden views stay in the responder chain otherwise.
  [g_main_window makeFirstResponder:nil];

  g_screenshot_mode_active = !g_screenshot_mode_active;
  BOOL active = g_screenshot_mode_active;

  if (active) {
    if (!g_screenshot_esc_monitor) {
      // Mirrors the command palette's and downloads popover's own Esc
      // monitors (bro_palette.mm, bro_downloads.mm): a local monitor is the
      // established way this codebase gives a transient mode first claim on
      // Escape without touching BroApplication's global sendEvent: path.
      g_screenshot_esc_monitor = [NSEvent
          addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                       handler:^NSEvent*(NSEvent* event) {
        if (event.keyCode == 53 /* Esc */) {
          ToggleScreenshotMode();
          return nil;
        }
        return event;
      }];
    }
  } else {
    RemoveScreenshotEscMonitor();
  }

  NSButton* closeButton = [g_main_window standardWindowButton:NSWindowCloseButton];
  NSButton* miniaturizeButton =
      [g_main_window standardWindowButton:NSWindowMiniaturizeButton];
  NSButton* zoomButton = [g_main_window standardWindowButton:NSWindowZoomButton];
  if (active) {
    g_screenshot_saved_close_hidden = closeButton.hidden;
    g_screenshot_saved_miniaturize_hidden = miniaturizeButton.hidden;
    g_screenshot_saved_zoom_hidden = zoomButton.hidden;
    closeButton.hidden = YES;
    miniaturizeButton.hidden = YES;
    zoomButton.hidden = YES;
  } else {
    closeButton.hidden = g_screenshot_saved_close_hidden;
    miniaturizeButton.hidden = g_screenshot_saved_miniaturize_hidden;
    zoomButton.hidden = g_screenshot_saved_zoom_hidden;
  }

  NSRect contentBounds = g_main_window.contentView.bounds;
  NSRect containerTarget =
      active ? NSInsetRect(contentBounds, kScreenshotModeGutter,
                           kScreenshotModeGutter)
             : NSMakeRect(0, 0, contentBounds.size.width,
                          contentBounds.size.height - kToolbarHeight);

  if (!active) {
    // Make the toolbar visible again before fading it in -- a hidden view's
    // alpha animation never draws.
    g_toolbar.hidden = NO;
    g_toolbar.alphaValue = 0.0;
  }

  // The card's own corner radius derives from the window's (bro_geometry's
  // concentric rule): normally browserContainer needs no rounding of its
  // own, since it fills edge-to-edge and the window's NSThemeFrame clips it
  // to the window shape for free (see BroShellCornerRadius above). Inset
  // from the edge by the gutter, it has to carry its own curve to read as a
  // card rather than a clipped rectangle.
  g_main_window.browserContainer.wantsLayer = YES;
  CALayer* containerLayer = g_main_window.browserContainer.layer;
  containerLayer.masksToBounds = YES;
  containerLayer.cornerCurve = kCACornerCurveContinuous;
  CGFloat cardRadius = active
      ? BroNestedCornerRadius(BroShellCornerRadius(), kScreenshotModeGutter)
      : 0.0;

  BroRunLayoutSpring(^{
    g_toolbar.animator.alphaValue = active ? 0.0 : 1.0;
    g_main_window.browserContainer.animator.frame = containerTarget;
    containerLayer.cornerRadius = cardRadius;
  }, ^{
    g_toolbar.hidden = active;
    UpdateChromeLayout();  // final snap: exact per-tab/divider frames
    BroHandler* handler = BroHandler::GetInstance();
    if (handler) {
      // Recomputes the glass backdrop now that g_screenshot_mode_active has
      // changed -- forces it on while active, restores the blank-tab-driven
      // default on exit. Attach/detach state is unchanged, so this is a
      // no-op for every container's frame.
      UpdateTabContainerVisibility(handler->GetActiveBrowserId());
    }
  });
}

#pragma mark - Split Screen

// Enters or exits split screen for |browser_id| (hover-card button and menu
// item). A non-active tab becomes the right pane; either pane toggles the
// split off; the active tab alone is a no-op (nothing to pair with).
// Declared extern in bro_mac_internal.h.
void ToggleSplitForTab(int browser_id) {
  BroHandler* handler = BroHandler::GetInstance();
  if (!handler) {
    return;
  }
  int active_id = handler->GetActiveBrowserId();
  if (SplitActive() &&
      (browser_id == g_split_browser_id || browser_id == active_id)) {
    ClearSplit();
  } else if (browser_id != active_id &&
             g_browser_views[@(browser_id)] != nil) {
    g_split_browser_id = browser_id;
    g_split_ratio = g_last_split_ratio;
  } else {
    return;
  }
  // Reorders the pair's pills to sit joined (or restores normal pills on
  // exit) and refreshes the pane styling either way.
  [g_tab_bar ensureSplitPairAdjacent];
  // The split layout is desktop-shaped: leave the mobile shell while split,
  // re-hug the active tab's viewport on exit. Either way the completion (or
  // the early-out) runs UpdateChromeLayout, which frames the panes.
  UpdateWindowForViewportMode(SplitActive() ? NO : TabIsMobile(active_id),
                              YES);
  UpdateTabContainerVisibility(active_id);
}

// Drag-to-join: a pill dropped onto another one splits the two tabs, the
// dragged tab active. Any prior split gives way to the new pair. Declared
// extern in bro_mac_internal.h.
void JoinTabsInSplit(int dragged_id, int target_id) {
  BroHandler* handler = BroHandler::GetInstance();
  if (!handler || dragged_id == target_id) {
    return;
  }
  if (SplitActive()) {
    ClearSplit();
  }
  // Main thread == CEF UI thread, so this activates synchronously and the
  // toggle below pairs the target with the freshly active dragged tab.
  handler->SetActiveBrowser(dragged_id);
  ToggleSplitForTab(target_id);
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
static NSView* g_zoom_hud_content = nil;
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
    g_zoom_hud.layer.cornerRadius = BroCornerRadiusForSize(
        BroSurfaceCornerRadius(), g_zoom_hud.bounds.size);
    BroApplyElevation(g_zoom_hud, BroElevationOverlay);
    g_zoom_hud_content =
        BroInstallGlassSurface(g_zoom_hud, g_zoom_hud.layer.cornerRadius);
    g_zoom_hud.hidden = YES;

    g_zoom_hud_label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    g_zoom_hud_label.editable = NO;
    g_zoom_hud_label.selectable = NO;
    g_zoom_hud_label.bezeled = NO;
    g_zoom_hud_label.bordered = NO;
    g_zoom_hud_label.drawsBackground = NO;
    g_zoom_hud_label.font = BroUIFontBold(14.0);
    g_zoom_hud_label.textColor = [NSColor labelColor];
    g_zoom_hud_label.alignment = NSTextAlignmentCenter;
    [g_zoom_hud_content addSubview:g_zoom_hud_label];
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
  g_zoom_hud.layer.cornerRadius = BroCornerRadiusForSize(
      BroSurfaceCornerRadius(), g_zoom_hud.bounds.size);
  g_zoom_hud_label.frame =
      NSMakeRect(padX, padY, labelSize.width, labelSize.height);

  BroOverlayShow(g_zoom_hud);

  [g_zoom_hud_timer invalidate];
  g_zoom_hud_timer =
      [NSTimer scheduledTimerWithTimeInterval:1.2
                                      repeats:NO
                                        block:^(NSTimer* timer) {
        g_zoom_hud_timer = nil;
        BroOverlayHide(g_zoom_hud);
      }];
}

static void CreateNewBrowserTabWithURLAndFocus(const std::string& url,
                                               BOOL focusAddressWhenReady) {
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

  if (focusAddressWhenReady) {
    [g_pending_address_focus_containers addObject:browserContainer];
  }

  // Create the browser with the specified URL. If creation is rejected
  // synchronously, discard the pending focus request with the container.
  if (!CefBrowserHost::CreateBrowser(window_info, handler, url,
                                     browser_settings, nullptr, nullptr)) {
    [g_pending_address_focus_containers removeObject:browserContainer];
    [browserContainer removeFromSuperview];
  }
}

// CreateNewBrowserTab(WithURL) are declared extern in bro_mac_internal.h.
void CreateNewBrowserTabWithURL(const std::string& url) {
  CreateNewBrowserTabWithURLAndFocus(url, NO);
}

void CreateNewBrowserTab(void) {
  CreateNewBrowserTabWithURLAndFocus("about:blank", YES);
}

#pragma mark - BroAppDelegate

// Quit-time capture for Reopen Closed Tab: snapshot every open tab into the
// closed-tab list synchronously, before CloseAllBrowsers starts. The per-tab
// OnTabClosed records can't be relied on here — they arrive via
// dispatch_async and race window teardown — so OnTabClosed skips recording
// while the handler reports a teardown and this snapshot stands alone.
static void BroSnapshotOpenTabsForReopen(void) {
  if (!g_tab_bar) {
    return;
  }
  for (BroTabView* tab in g_tab_bar.tabs) {
    if (tab.tabURL.length > 0 && !BroURLIsBlank(tab.tabURL)) {
      BroRecordClosedTab(tab.tabURL, tab.pageTitle, tab.faviconURL);
    }
  }
  // The quit paths are also the last chance to flush a debounced history
  // write — the pending dispatch_after never fires once the loop stops.
  BroHistorySaveNow();
}

// History menu: everything after the item with this tag is rebuilt from the
// history store each time the menu opens.
static const NSInteger kBroHistorySeparatorTag = 0xB40;
static const NSUInteger kBroHistoryMenuMaxItems = 15;

// Menu titles get a middle ellipsis so the distinguishing tail of long page
// titles/URLs (the part that differs between similar pages) stays visible.
static NSString* BroTruncateMenuTitle(NSString* title, NSUInteger maxLength) {
  if (title.length <= maxLength) {
    return title;
  }
  NSUInteger head = maxLength / 2;
  NSUInteger tail = maxLength - head - 1;
  return [NSString stringWithFormat:@"%@…%@", [title substringToIndex:head],
                                    [title substringFromIndex:title.length - tail]];
}

@interface BroAppDelegate
    : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate>
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

  // A repeated downloads-row shortcut is only meaningful when one magnifier
  // is focused or hovered. Resolve it before the normal menu/event pass so it
  // can never reveal an arbitrary file.
  if (event.window == g_main_window &&
      BroPerformContextualDownloadsShortcut(event)) {
    return;
  }

  // Route in-page Find before AppKit's field editor sees the event. Generic
  // Find selectors are otherwise consumed as text-field operations while the
  // native query field is focused instead of reaching the browser command.
  if (event.type == NSEventTypeKeyDown && event.window == g_main_window) {
    NSEventModifierFlags relevant =
        NSEventModifierFlagCommand | NSEventModifierFlagShift |
        NSEventModifierFlagControl | NSEventModifierFlagOption;
    NSEventModifierFlags mods =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
        relevant;
    NSString* chars = event.charactersIgnoringModifiers.lowercaseString;
    if ([chars isEqualToString:@"f"] &&
        mods == NSEventModifierFlagCommand) {
      BroShowFindBar();
      return;
    }
    if ([chars isEqualToString:@"g"] &&
        (mods == NSEventModifierFlagCommand ||
         mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift))) {
      if (mods & NSEventModifierFlagShift) {
        BroFindPrevious();
      } else {
        BroFindNext();
      }
      return;
    }
  }

  // Ctrl+Tab / Ctrl+Shift+Tab and Ctrl+PageDown / Ctrl+PageUp cycle tabs.
  // Tab cannot be a menu key
  // equivalent: Tab is consumed for focus traversal before the menu pass
  // when the browser view is first responder. Only the main window cycles;
  // DevTools and other windows keep their native behavior.
  if (event.type == NSEventTypeKeyDown && event.window == g_main_window &&
      g_tab_bar &&
      (event.keyCode == 48 /* kVK_Tab */ ||
       event.keyCode == 116 /* kVK_PageUp */ ||
       event.keyCode == 121 /* kVK_PageDown */)) {
    NSEventModifierFlags mods =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL ctrlOnly =
        (mods & NSEventModifierFlagControl) != 0 &&
        (mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) == 0;
    if (ctrlOnly) {
      BOOL previous = event.keyCode == 116 ||
                      (event.keyCode == 48 &&
                       (mods & NSEventModifierFlagShift));
      [g_tab_bar activateTabRelativeToActiveWithOffset:
                     previous ? -1 : 1];
      return;
    }
  }

  // Escape closes in-page Find even if keyboard focus has moved from its
  // search field to one of the result-navigation buttons.
  if (event.type == NSEventTypeKeyDown && event.keyCode == 53 &&
      event.window == g_main_window && BroFindBarVisible()) {
    BroHideFindBar();
    return;
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

  // The thumb buttons on most mice navigate history, like every other browser.
  // macOS numbers them 3 (back) and 4 (forward). Handled here for the same
  // reason as Cmd+Left/Right above: CEF's windowed mac view never forwards
  // them to the renderer, so no page can act on them.
  if ((event.type == NSEventTypeOtherMouseDown ||
       event.type == NSEventTypeOtherMouseUp) &&
      (event.buttonNumber == 3 || event.buttonNumber == 4) &&
      event.window == g_main_window) {
    // Local NSEvent monitors run inside -[NSApplication sendEvent:]'s call to
    // super, so the tab search panel's and downloads popover's outside-click
    // monitors never see these buttons -- dismiss explicitly here, the only
    // place that can.
    BroDismissTransientOverlays();
    // Navigate on the press; the release is swallowed too so no view is left
    // tracking a button-down it never saw finish.
    if (event.type == NSEventTypeOtherMouseDown) {
      BroHandler* handler = BroHandler::GetInstance();
      CefRefPtr<CefBrowser> browser = handler ? handler->GetBrowser() : nullptr;
      if (browser) {
        if (event.buttonNumber == 3 && browser->CanGoBack()) {
          browser->GoBack();
        } else if (event.buttonNumber == 4 && browser->CanGoForward()) {
          browser->GoForward();
        }
      }
    }
    return;
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
  // Regular Liquid Glass owns local light/dark adaptation on macOS 26+.
  // Older systems keep Bro's established dark HUD fallback unchanged.
  if (@available(macOS 26.0, *)) {
    NSApp.appearance = nil;
  } else {
    NSApp.appearance =
        [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  }

  // Before the menu, so the "Check for Updates…" item can bind to a live
  // updater rather than a nil target.
  BroStartUpdater();

  // Create the main menu
  [self setupMainMenu];

  // Create the main window
  g_main_window = [[BroWindow alloc] init];
  g_main_window.delegate = self;
  g_main_window.title = @"Bro Computer";

  // Order the window while transparent so the behind-window material can
  // attach and AppKit can commit the complete shell before any pixels become
  // visible. Cold launches from a DMG otherwise expose the window server's
  // black initial backing store for a frame before the glass surface resolves.
  g_main_window.alphaValue = 0.0;
  [g_main_window makeKeyAndOrderFront:nil];
  [g_main_window.contentView layoutSubtreeIfNeeded];
  [g_main_window displayIfNeeded];
  [CATransaction flush];

  // Reveal without animation on the next main-queue turn, after the initial
  // layer transaction has been submitted. Keep this independent of CEF's
  // asynchronous browser creation so a slow or failed browser startup cannot
  // leave the native window invisible.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_main_window) {
      return;
    }
    [g_main_window.contentView layoutSubtreeIfNeeded];
    [g_main_window displayIfNeeded];
    [CATransaction flush];
    g_main_window.alphaValue = 1.0;
  });

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

  [appMenu addItemWithTitle:@"About Bro Computer"
                     action:@selector(orderFrontStandardAboutPanel:)
              keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];

  // Sparkle drives this item itself: it owns the target and keeps the item
  // enabled or disabled depending on whether a check is allowed right now. On
  // a build without update keys the target is nil, so the item stays greyed.
  NSMenuItem* updateItem =
      [appMenu addItemWithTitle:@"Check for Updates…"
                         action:BroUpdaterMenuAction()
                  keyEquivalent:@""];
  updateItem.target = BroUpdaterMenuTarget();
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit Bro Computer"
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
  [editMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* findMenuItem = [[NSMenuItem alloc] initWithTitle:@"Find"
                                                       action:nil
                                                keyEquivalent:@""];
  NSMenu* findMenu = [[NSMenu alloc] initWithTitle:@"Find"];
  [findMenu addItemWithTitle:@"Find…"
                      action:@selector(showFindBar:)
               keyEquivalent:@"f"];
  [findMenu addItemWithTitle:@"Find Next"
                      action:@selector(findNextInPage:)
               keyEquivalent:@"g"];
  NSMenuItem* findPreviousItem =
      [findMenu addItemWithTitle:@"Find Previous"
                          action:@selector(findPreviousInPage:)
                   keyEquivalent:@"g"];
  findPreviousItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  findMenuItem.submenu = findMenu;
  [editMenu addItem:findMenuItem];

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

  NSMenuItem* downloadsItem =
      [viewMenu addItemWithTitle:@"Downloads"
                          action:@selector(showDownloads:)
                   keyEquivalent:@"j"];
  downloadsItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  NSMenuItem* desktopItem =
      [viewMenu addItemWithTitle:@"Desktop Viewport"
                          action:@selector(selectDesktopViewport:)
                   keyEquivalent:@"d"];
  desktopItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  NSMenuItem* mobileItem =
      [viewMenu addItemWithTitle:@"Mobile Viewport"
                          action:@selector(selectMobileViewport:)
                   keyEquivalent:@"m"];
  mobileItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  // Screenshot mode: hides the chrome so the page floats as a rounded card
  // inside the glass gutter. Plain Cmd+S -- Split Screen uses Cmd+Shift+S,
  // so the two don't collide.
  [viewMenu addItemWithTitle:@"Screenshot Mode"
                       action:@selector(toggleScreenshotMode:)
                keyEquivalent:@"s"];
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

  viewMenuItem.submenu = viewMenu;
  [mainMenu addItem:viewMenuItem];

  // History menu: Back/Forward stay fixed; everything after the tagged
  // separator is rebuilt from the history store each time the menu opens
  // (menuNeedsUpdate:).
  NSMenuItem* historyMenuItem = [[NSMenuItem alloc] init];
  NSMenu* historyMenu = [[NSMenu alloc] initWithTitle:@"History"];
  historyMenu.delegate = self;

  NSString* leftArrow =
      [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
  NSString* rightArrow =
      [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
  NSMenuItem* backItem = [historyMenu addItemWithTitle:@"Back"
                                                action:@selector(goBack:)
                                         keyEquivalent:leftArrow];
  backItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;

  NSMenuItem* forwardItem = [historyMenu addItemWithTitle:@"Forward"
                                                   action:@selector(goForward:)
                                            keyEquivalent:rightArrow];
  forwardItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;

  // Keep the established bracket aliases active without advertising two
  // different primary bindings in the menu or toolbar tooltip.
  NSMenuItem* backBracket = [[NSMenuItem alloc] initWithTitle:@"Back"
                                                       action:@selector(goBack:)
                                                keyEquivalent:@"["];
  backBracket.hidden = YES;
  [historyMenu addItem:backBracket];
  NSMenuItem* forwardBracket = [[NSMenuItem alloc] initWithTitle:@"Forward"
                                                          action:@selector(goForward:)
                                                   keyEquivalent:@"]"];
  forwardBracket.hidden = YES;
  [historyMenu addItem:forwardBracket];

  NSMenuItem* recentsSeparator = [NSMenuItem separatorItem];
  recentsSeparator.tag = kBroHistorySeparatorTag;
  [historyMenu addItem:recentsSeparator];

  historyMenuItem.submenu = historyMenu;
  [mainMenu addItem:historyMenuItem];

  // File menu (for tab operations)
  NSMenuItem* fileMenuItem = [[NSMenuItem alloc] init];
  NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

  [fileMenu addItemWithTitle:@"New Window"
                      action:@selector(newWindow:)
               keyEquivalent:@"n"];
  [fileMenu addItemWithTitle:@"New Tab"
                      action:@selector(newTab:)
               keyEquivalent:@"t"];
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
  [fileMenu addItemWithTitle:@"Command Palette…"
                      action:@selector(showCommandPalette:)
               keyEquivalent:@"k"];

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

  // Tab actions; validateMenuItem: retitles them to match the current state.
  [windowMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* pinItem =
      [windowMenu addItemWithTitle:@"Pin Tab"
                            action:@selector(togglePinActiveTab:)
                     keyEquivalent:@"p"];
  pinItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagOption;
  NSMenuItem* splitItem = [windowMenu addItemWithTitle:@"Split Screen"
                                                action:@selector(toggleSplitScreen:)
                                         keyEquivalent:@"s"];
  splitItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  NSMenuItem* tabSearchItem = [windowMenu addItemWithTitle:@"Search Tabs…"
                                                    action:@selector(showTabSearch:)
                                             keyEquivalent:@"a"];
  tabSearchItem.keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;

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
  [g_pending_address_focus_containers addObject:browserContainer];
  if (!CefBrowserHost::CreateBrowser(window_info, handler, url,
                                     browser_settings, nullptr, nullptr)) {
    [g_pending_address_focus_containers removeObject:browserContainer];
    [browserContainer removeFromSuperview];
  }

  if (g_toolbar) {
    [g_toolbar updateURL:@""];
  }
}

- (void)tryToTerminateApplication:(NSApplication*)app {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler && !handler->IsClosing() && !handler->IsClosingAll()) {
    // ⌘Q comes through here (BroApplication.terminate:), not
    // windowShouldClose:, so the quit snapshot must happen in both paths.
    BroSnapshotOpenTabsForReopen();
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
  BroDismissTransientOverlays();
  if (g_toolbar) {
    [g_toolbar goBack:sender];
  }
}

- (void)goForward:(id)sender {
  BroDismissTransientOverlays();
  if (g_toolbar) {
    [g_toolbar goForward:sender];
  }
}

#pragma mark - History menu

// Rebuilds the dynamic tail of the History menu (recents + Clear History…)
// from the store each time the menu opens. Only the History menu sets this
// delegate.
- (void)menuNeedsUpdate:(NSMenu*)menu {
  NSInteger anchor = [menu indexOfItemWithTag:kBroHistorySeparatorTag];
  if (anchor < 0) {
    return;
  }
  while (menu.numberOfItems > anchor + 1) {
    [menu removeItemAtIndex:menu.numberOfItems - 1];
  }

  NSArray<BroHistoryEntry*>* history = BroHistoryEntries();
  if (history.count == 0) {
    NSMenuItem* empty = [[NSMenuItem alloc] initWithTitle:@"No History"
                                                   action:nil
                                            keyEquivalent:@""];
    empty.enabled = NO;
    [menu addItem:empty];
  } else {
    NSUInteger added = 0;
    for (BroHistoryEntry* entry in history.reverseObjectEnumerator) {
      NSString* title = entry.title.length > 0
                            ? entry.title
                            : BroDisplayHostForURL(entry.url);
      NSMenuItem* item =
          [[NSMenuItem alloc] initWithTitle:BroTruncateMenuTitle(title, 50)
                                     action:@selector(historyItemSelected:)
                              keyEquivalent:@""];
      item.representedObject = entry.url;
      item.toolTip = entry.url;
      [menu addItem:item];
      if (++added >= kBroHistoryMenuMaxItems) {
        break;
      }
    }
  }

  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"Clear History…"
                  action:@selector(clearHistory:)
           keyEquivalent:@""];
}

// Loads in the current tab, like Safari's History menu; a new tab would
// silently pile up strip clutter for what is a "take me back there" gesture.
- (void)historyItemSelected:(NSMenuItem*)sender {
  NSString* url = sender.representedObject;
  if (![url isKindOfClass:[NSString class]] || url.length == 0) {
    return;
  }
  BroHandler* handler = BroHandler::GetInstance();
  CefRefPtr<CefBrowser> browser = handler ? handler->GetBrowser() : nullptr;
  if (browser) {
    browser->GetMainFrame()->LoadURL([url UTF8String]);
  } else {
    CreateNewBrowserTabWithURL(std::string([url UTF8String]));
  }
}

- (void)clearHistory:(id)sender {
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Clear History?";
  alert.informativeText =
      @"This removes every page from the History menu. It does not clear "
      @"cookies or the browsing cache.";
  [alert addButtonWithTitle:@"Clear History"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn) {
    BroHistoryClear();
  }
}

- (void)reloadPage:(id)sender {
  BroDismissTransientOverlays();
  if (g_toolbar) {
    [g_toolbar refresh:sender];
  }
}

- (void)hardReload:(id)sender {
  BroDismissTransientOverlays();
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
  // The user needs the chrome back to see the new tab land.
  if (g_screenshot_mode_active) {
    ToggleScreenshotMode();
  }
  CreateNewBrowserTab();
}

- (void)newWindow:(id)sender {
  NSURL* applicationURL = NSBundle.mainBundle.bundleURL;
  if (!applicationURL) {
    return;
  }

  // CEF holds a process lock on its profile directory. This codebase's
  // window state is intentionally single-window, so launch a second app
  // instance with an isolated temporary profile instead of corrupting the
  // live profile or relabeling a tab as a window.
  NSString* profile = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSString
          stringWithFormat:@"Bro-New-Window-%@", NSUUID.UUID.UUIDString]];
  NSWorkspaceOpenConfiguration* configuration =
      [NSWorkspaceOpenConfiguration configuration];
  configuration.createsNewApplicationInstance = YES;
  configuration.activates = YES;
  configuration.addsToRecentItems = NO;
  configuration.environment = @{ @"BRO_USER_DATA_DIR" : profile };
  [[NSWorkspace sharedWorkspace]
      openApplicationAtURL:applicationURL
             configuration:configuration
         completionHandler:^(NSRunningApplication* application,
                             NSError* error) {
    if (error) {
      NSLog(@"Unable to open a new browser window: %@", error);
    }
  }];
}

- (void)showFindBar:(id)sender {
  BroShowFindBar();
}

- (void)findNextInPage:(id)sender {
  BroFindNext();
}

- (void)findPreviousInPage:(id)sender {
  BroFindPrevious();
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
  BroClosedTabEntry* entry = BroClosedTabsList().lastObject;
  if (!entry || entry.url.length == 0) {
    return;
  }
  BroRemoveClosedTab(entry);
  CreateNewBrowserTabWithURL(std::string([entry.url UTF8String]));
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

- (void)togglePinActiveTab:(id)sender {
  if ([g_tab_bar performContextualPinShortcut]) {
    return;
  }
  BroDismissTransientOverlays();
  for (BroTabView* tab in g_tab_bar.tabs) {
    if (tab.browserId == g_tab_bar.activeTabId) {
      [g_tab_bar togglePinForTab:tab];
      return;
    }
  }
}

- (void)toggleSplitScreen:(id)sender {
  if ([g_tab_bar performContextualSplitShortcut]) {
    return;
  }
  BroDismissTransientOverlays();
  if (SplitActive()) {
    ToggleSplitForTab(g_split_browser_id);
    return;
  }
  [g_tab_bar splitActiveTabWithNextTab];
}

- (void)showCommandPalette:(id)sender {
  ToggleCommandPalette(BroPaletteScopeAll);
}

- (void)showDownloads:(id)sender {
  HideCommandPalette();
  BroToggleDownloadsPopover();
}

- (void)selectDesktopViewport:(id)sender {
  BroDismissTransientOverlays();
  [g_toolbar selectDesktopMode:sender];
}

- (void)selectMobileViewport:(id)sender {
  BroDismissTransientOverlays();
  [g_toolbar selectMobileMode:sender];
}

// ⇧⌘A and the tab strip's chevron keep their tab-search identity; they open
// the same palette pre-scoped to tabs.
- (void)showTabSearch:(id)sender {
  ToggleCommandPalette(BroPaletteScopeTabs);
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
  if (action == @selector(clearHistory:)) {
    return BroHistoryEntries().count > 0;
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
    return BroClosedTabsCount() > 0;
  }
  if (action == @selector(showDownloads:)) {
    return g_toolbar != nil && BroHasRecentDownloads();
  }
  if (action == @selector(selectDesktopViewport:) ||
      action == @selector(selectMobileViewport:)) {
    BroHandler* handler = BroHandler::GetInstance();
    int activeId = handler ? handler->GetActiveBrowserId() : -1;
    if (!handler || activeId < 0) {
      menuItem.state = NSControlStateValueOff;
      return NO;
    }
    BOOL mobile = handler->IsTabMobile(activeId);
    BOOL itemSelected = action == @selector(selectMobileViewport:)
                            ? mobile
                            : !mobile;
    menuItem.state = itemSelected ? NSControlStateValueOn
                                  : NSControlStateValueOff;
    return YES;
  }
  if (action == @selector(togglePinActiveTab:)) {
    BroTabView* active = nil;
    for (BroTabView* tab in g_tab_bar.tabs) {
      if (tab.browserId == g_tab_bar.activeTabId) {
        active = tab;
        break;
      }
    }
    menuItem.title = active.pinned ? @"Unpin Tab" : @"Pin Tab";
    return active != nil;
  }
  if (action == @selector(toggleSplitScreen:)) {
    menuItem.title = SplitActive() ? @"Exit Split Screen" : @"Split Screen";
    return SplitActive() || (g_tab_bar && g_tab_bar.tabs.count > 1);
  }
  if (action == @selector(toggleScreenshotMode:)) {
    menuItem.state = g_screenshot_mode_active ? NSControlStateValueOn
                                              : NSControlStateValueOff;
    return YES;
  }
  return YES;
}

- (void)toggleScreenshotMode:(id)sender {
  ToggleScreenshotMode();
}

- (void)focusAddressBar:(id)sender {
  BroDismissTransientOverlays();
  // Typing needs the chrome back.
  if (g_screenshot_mode_active) {
    ToggleScreenshotMode();
  }
  if (g_toolbar) {
    [g_toolbar focusAddressField];
  }
}

- (void)stepZoom:(BOOL)zoomingIn {
  BroDismissTransientOverlays();
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
  BroDismissTransientOverlays();
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
  if (handler && !handler->IsClosing() && !handler->IsClosingAll()) {
    BroSnapshotOpenTabsForReopen();
    handler->CloseAllBrowsers(false);
    return NO;  // Don't close yet, wait for browsers to close
  }
  return YES;
}

- (void)windowWillClose:(NSNotification*)notification {
  HideCommandPalette();
  BroHideFindBar();
  // The retained palette belongs to the dying window's view tree; rebuild it
  // fresh for any future window.
  TeardownCommandPalette();
  BroTeardownFindBar();
  g_main_window = nil;
  g_toolbar = nil;
  g_tab_bar = nil;
  g_split_browser_id = -1;
  g_split_ratio = 0.5;
  g_split_divider = nil;
  [g_browser_views removeAllObjects];
  [g_blank_tab_ids removeAllObjects];
  [g_fading_out_ids removeAllObjects];
  ++g_glass_transition_token;
  [g_glass_transition_overlay removeFromSuperview];
  g_glass_transition_overlay = nil;
  // The closed-tab list intentionally survives: it is persisted and feeds
  // Reopen Closed Tab across launches.
  // Flush any debounced history writes before the app winds down.
  BroHistorySaveNow();
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
// BroRunOnMain is declared extern in bro_mac_internal.h.
void BroRunOnMain(void (^block)(void)) {
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

  BOOL shouldFocusAddress =
      [g_pending_address_focus_containers containsObject:container];
  [g_pending_address_focus_containers removeObject:container];

  g_browser_views[@(browser_id)] = container;

  // If this was a popup's container, it is no longer pending.
  for (NSNumber* popupId in [g_pending_popup_containers allKeysForObject:container]) {
    [g_pending_popup_containers removeObjectForKey:popupId];
  }

  // New browsers usually arrive before their first commit (empty URL), so
  // they start blank and unhide when a real URL commits.
  NSString* urlStr = [NSString stringWithUTF8String:url.c_str()] ?: @"";
  if (BroURLIsBlank(urlStr)) {
    [g_blank_tab_ids addObject:@(browser_id)];
  }

  // A tab opened while a mobile-emulated tab is active inherits that mode.
  // The shell hugs the mobile viewport for as long as such a tab is active,
  // so a desktop-mode new tab would snap the window back to the desktop frame
  // and re-lay the chrome on every ⌘T / + click. The outgoing tab is still
  // the active one here: OnAfterCreated promotes this browser only after
  // adoption returns. Applied before the tab bar work below so the toolbar's
  // viewport toggles (updated from setActiveTab:) show the inherited mode.
  // The DevTools overrides themselves land a turn later -- see
  // AdoptTabMobileEmulation; issuing them from inside OnAfterCreated crashes.
  BroHandler* creating_handler = BroHandler::GetInstance();
  int outgoing_id =
      creating_handler ? creating_handler->GetActiveBrowserId() : -1;
  if (creating_handler && outgoing_id >= 0 && outgoing_id != browser_id &&
      creating_handler->IsTabMobile(outgoing_id)) {
    creating_handler->AdoptTabMobileEmulation(browser_id);
  }

  // Add tab to tab bar
  if (g_tab_bar) {
    [g_tab_bar addTabWithBrowserId:browser_id title:kBroBlankTabTitle];
    [g_tab_bar updateTabURL:browser_id url:urlStr];
    [g_tab_bar setActiveTab:browser_id];
  }

  UpdateTabContainerVisibility(browser_id);

  // A newly adopted tab becomes active without going through
  // OnActiveTabChanged; the shell follows its viewport mode (inherited from
  // the tab it replaced, above). While split the shell stays desktop-shaped,
  // as it does on every other tab switch.
  UpdateWindowForViewportMode(SplitActive() ? NO : TabIsMobile(browser_id),
                              YES);

  if (shouldFocusAddress) {
    // Let adoption and layout finish before asking AppKit for its field
    // editor. The active-ID and blank-URL guards make multiple rapid new-tab
    // requests deterministic: only the latest still-blank tab receives focus.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!g_tab_bar || g_tab_bar.activeTabId != browser_id) {
        return;
      }
      BroTabView* tab = [g_tab_bar tabWithBrowserId:browser_id];
      if (tab && BroURLIsBlank(tab.tabURL)) {
        [tab focusAddressField];
      }
    });
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
    if (browser_id == g_split_browser_id) {
      ClearSplit();
    }
    NSView* containerView = g_browser_views[@(browser_id)];
    if (containerView) {
      // Blank and background tabs are already detached (render throttling),
      // so removing them again is a no-op and CEF never sees the
      // window-detach transition this close is waiting on. Cycle through an
      // attached state to generate it.
      if (!containerView.superview && g_main_window.browserContainer) {
        containerView.hidden = YES;
        [g_main_window.browserContainer addSubview:containerView];
      }
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
      // Titles arrive after the URL commit; backfill the history entry.
      BroHistoryUpdateTitle([g_tab_bar tabWithBrowserId:browser_id].tabURL,
                            titleStr);
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
    // OnAddressChange is main-frame-only and fires at commit — the one
    // reliable "the user visited this" signal.
    BroHistoryRecordVisit(browser_id, urlStr);

    // Commit-time blank/loaded transition: unhide the CEF view for real
    // pages, return to the blank state when the tab navigates back to
    // about:blank.
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
      BroHistoryUpdateFavicon([g_tab_bar tabWithBrowserId:browser_id].tabURL,
                              urlStr);
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
    // The palette's open-tab rows are now stale; it also self-hides after
    // reopening a closed tab (which lands here for the departing tab's id
    // only on real closes, not reopens — either way hiding is safe).
    HideCommandPalette();
    // Remove from tab bar
    if (g_tab_bar) {
      // Record the tab for Reopen Closed Tab and the tab search panel's
      // "Recently Closed" section while the pill still exists. Blank/new-tab
      // pages aren't worth reopening.
      //
      // During quit (CloseAllBrowsers) every open tab lands here; those were
      // already snapshotted synchronously by the quit path, so skip the
      // per-tab recording to avoid duplicates. IsClosingAll covers the first
      // N-1 browsers of a teardown, IsClosing the last — and a null handler
      // means teardown already released it before this deferred block ran
      // (it outlives every individual close), so that counts too.
      BroHandler* closing_handler = BroHandler::GetInstance();
      BOOL tearing_down =
          !closing_handler || closing_handler->IsClosing() ||
          closing_handler->IsClosingAll();
      for (BroTabView* tab in g_tab_bar.tabs) {
        if (tab.browserId == browser_id) {
          if (!tearing_down && tab.tabURL.length > 0 &&
              !BroURLIsBlank(tab.tabURL)) {
            BroRecordClosedTab(tab.tabURL, tab.pageTitle, tab.faviconURL);
          }
          break;
        }
      }
      [g_tab_bar removeTabWithBrowserId:browser_id];
    }

    // A closed split pane ends the split; the survivor goes full-bleed below.
    if (browser_id == g_split_browser_id) {
      ClearSplit();
    }

    // Remove and destroy the container view
    NSView* containerView = g_browser_views[@(browser_id)];
    if (containerView) {
      [containerView removeFromSuperview];
      [g_browser_views removeObjectForKey:@(browser_id)];
    }
    [g_blank_tab_ids removeObject:@(browser_id)];
    BroHistoryTabClosed(browser_id);

    BroHandler* handler = BroHandler::GetInstance();
    if (handler && g_main_window) {
      UpdateTabContainerVisibility(handler->GetActiveBrowserId());
      UpdateChromeLayout();
    }
  });
}

void OnActiveTabChanged(int browser_id) {
  BroRunOnMain(^{
    // Any tab switch dismisses the palette: switches from inside it hide
    // explicitly too (idempotent), and outside ones (⌘1-9, Ctrl+Tab) would
    // otherwise leave it floating over the new page.
    HideCommandPalette();
    // Selecting the right pane swaps panes instead of ending the split: the
    // outgoing active tab takes the right slot and the clicked tab becomes
    // the active/left one, so the address bar and shortcuts follow it.
    if (SplitActive() && browser_id == g_split_browser_id && g_tab_bar &&
        g_tab_bar.activeTabId != browser_id) {
      g_split_browser_id = g_tab_bar.activeTabId;
    }

    // Update tab bar
    if (g_tab_bar) {
      [g_tab_bar setActiveTab:browser_id];
      // The pair may have changed (pane swap above, or a third tab replacing
      // the left pane); keep its pills joined and styled.
      if (SplitActive()) {
        [g_tab_bar ensureSplitPairAdjacent];
      }
    }

    UpdateTabContainerVisibility(browser_id);

    // The shell follows the active tab's viewport mode; while split it stays
    // desktop-shaped regardless of per-tab emulation.
    UpdateWindowForViewportMode(SplitActive() ? NO : TabIsMobile(browser_id),
                                YES);
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
    // compiled-code caches between launches). BroUserDataDirectory honors
    // BRO_USER_DATA_DIR so test harnesses can run isolated instances
    // concurrently (the profile directory holds the process-singleton lock,
    // so two instances sharing it cannot both launch); the same directory
    // holds the closed-tab and history JSON files.
    NSString* cachePath = BroUserDataDirectory();
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
    // popups and navigations never flash a lighter rectangle over the black
    // chrome.
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
