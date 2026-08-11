// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "bro_handler.h"
#import "bro_mac_internal.h"
#import "bro_closed_tabs.h"
#import "radix_icons.h"

#pragma mark - BroTabSearchPanel

static const CGFloat kTabSearchPanelWidth = 340.0;
static const CGFloat kTabSearchRowHeight = 32.0;
static const CGFloat kTabSearchHeaderHeight = 24.0;
// The list scrolls past this; the search row above never scrolls away.
static const CGFloat kTabSearchListMaxHeight = 352.0;
static const CGFloat kTabSearchFieldRowHeight = 44.0;
static const CGFloat kTabSearchPadX = 8.0;

// One row in the tab search panel: favicon + title, hover highlight, and a
// selection highlight driven by the panel's ↑/↓ navigation. A plain view
// rather than BroHoverButton: the hover scale reads wrong on a wide list row.
@interface BroTabSearchRow : NSView
// Open-tab rows carry the browser to activate; closed rows carry the entry
// to reopen. Exactly one is set.
@property (nonatomic, assign) int browserId;
@property (nonatomic, strong) BroClosedTabEntry* closedEntry;
@property (nonatomic, assign) BOOL selected;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
- (void)setTitle:(NSString*)title;
// Copies the pill's already-resolved favicon (image + placeholder tint).
- (void)adoptFaviconFrom:(NSImageView*)source;
// Async fetch for closed rows; shows the globe placeholder meanwhile.
- (void)setFaviconURLString:(NSString*)urlString;
@end

@implementation BroTabSearchRow {
  NSImageView* faviconView_;
  NSTextField* titleLabel_;
  BOOL hovered_;
  // Same guard as BroTabView: a stale fetch must not overwrite the favicon
  // this row was last configured with. Main-thread only.
  NSUInteger faviconGeneration_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _browserId = -1;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6.0;
    self.layer.actions = BroLayerTransitionActions();

    faviconView_ = [[NSImageView alloc]
        initWithFrame:NSMakeRect(10, (frame.size.height - 15) / 2.0, 15, 15)];
    faviconView_.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:faviconView_];
    [self showPlaceholderFavicon];

    titleLabel_ = BroHoverCardLabel(BroUIFont(12.0), 0.9);
    titleLabel_.frame = NSMakeRect(34, (frame.size.height - 16) / 2.0,
                                   frame.size.width - 34 - 10, 16);
    titleLabel_.autoresizingMask = NSViewWidthSizable;
    [self addSubview:titleLabel_];

    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityButtonRole;

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

- (void)setTitle:(NSString*)title {
  titleLabel_.stringValue = title ?: @"";
  self.accessibilityLabel = titleLabel_.stringValue;
}

- (void)showPlaceholderFavicon {
  faviconView_.image = RadixIconImage(RadixIconGlobe, 15);
  faviconView_.contentTintColor =
      [NSColor colorWithWhite:0x33 / 255.0 alpha:1.0];
}

- (void)adoptFaviconFrom:(NSImageView*)source {
  faviconGeneration_++;
  if (source.image) {
    faviconView_.image = source.image;
    faviconView_.contentTintColor = source.contentTintColor;
  } else {
    [self showPlaceholderFavicon];
  }
}

- (void)setFaviconURLString:(NSString*)urlString {
  NSUInteger generation = ++faviconGeneration_;
  [self showPlaceholderFavicon];
  if (urlString.length == 0) {
    return;
  }
  __weak BroTabSearchRow* weakSelf = self;
  BroFetchFaviconGuarded(
      urlString, generation,
      ^BOOL(NSUInteger g) {
        BroTabSearchRow* strongSelf = weakSelf;
        return strongSelf && strongSelf->faviconGeneration_ == g;
      },
      ^(NSImage* image) {
        BroTabSearchRow* strongSelf = weakSelf;
        strongSelf->faviconView_.image = image;
        strongSelf->faviconView_.contentTintColor = nil;
      });
}

- (void)refreshBackground {
  CGFloat alpha = _selected ? 0.14 : (hovered_ ? 0.07 : 0.0);
  self.layer.backgroundColor =
      alpha > 0 ? [NSColor colorWithWhite:1.0 alpha:alpha].CGColor
                : [NSColor clearColor].CGColor;
}

- (void)setSelected:(BOOL)selected {
  _selected = selected;
  [self refreshBackground];
}

- (void)mouseEntered:(NSEvent*)event {
  hovered_ = YES;
  [self refreshBackground];
}

- (void)mouseExited:(NSEvent*)event {
  hovered_ = NO;
  [self refreshBackground];
}

- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

- (void)mouseDown:(NSEvent*)event {
  // Claim the click; activation fires on mouse-up inside, like a button.
}

- (void)mouseUp:(NSEvent*)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (NSPointInRect(point, self.bounds)) {
    [NSApp sendAction:_action to:_target from:self];
  }
}

@end

// Flipped host for the row list so rows stack top-down in the scroll view.
@interface BroTabSearchListView : NSView
@end

@implementation BroTabSearchListView
- (BOOL)isFlipped {
  return YES;
}
@end

// The ⇧⌘A dropdown: a search field over a scrollable list of open tabs and
// recently closed entries. Typing filters both sections; ↑/↓/Return navigate
// and activate; Escape or an outside click dismisses. Same overlay recipe as
// the hover card: hand-rolled, re-added last to the browser container on
// every show, retained and hidden rather than destroyed.
@interface BroTabSearchPanel : NSView <NSTextFieldDelegate>
// Clears the query, rebuilds the list, and positions the panel; the caller
// unhides it and focuses the field.
- (void)prepareForDisplay;
- (void)focusSearchField;
// Hands keyboard focus back if the search field's editor still holds it.
- (void)restoreFocusIfNeeded;
@end

@implementation BroTabSearchPanel {
  NSTextField* searchField_;
  NSImageView* searchIcon_;
  NSTextField* shortcutHint_;
  NSView* separator_;
  NSScrollView* scrollView_;
  BroTabSearchListView* listView_;
  NSMutableArray<BroTabSearchRow*>* rows_;
  NSInteger selectedIndex_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    rows_ = [NSMutableArray array];
    selectedIndex_ = -1;

    self.wantsLayer = YES;
    self.layer.cornerRadius = 8.0;
    self.layer.backgroundColor =
        [NSColor colorWithWhite:0.18 alpha:0.96].CGColor;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor =
        [NSColor colorWithWhite:1.0 alpha:kWindowBorderAlpha].CGColor;

    searchIcon_ = [[NSImageView alloc] initWithFrame:NSZeroRect];
    searchIcon_.image = RadixIconImage(RadixIconMagnifyingGlass, 15);
    searchIcon_.contentTintColor = [NSColor colorWithWhite:1.0 alpha:0.55];
    [self addSubview:searchIcon_];

    searchField_ = [[NSTextField alloc] initWithFrame:NSZeroRect];
    searchField_.font = BroUIFont(13.0);
    searchField_.textColor = [NSColor whiteColor];
    searchField_.bordered = NO;
    searchField_.bezeled = NO;
    searchField_.drawsBackground = NO;
    searchField_.focusRingType = NSFocusRingTypeNone;
    searchField_.cell.usesSingleLineMode = YES;
    searchField_.cell.scrollable = YES;
    searchField_.placeholderAttributedString = [[NSAttributedString alloc]
        initWithString:@"Search tabs"
            attributes:@{
              NSFontAttributeName : BroUIFont(13.0),
              NSForegroundColorAttributeName :
                  [NSColor colorWithWhite:1.0 alpha:0.35],
            }];
    searchField_.delegate = self;
    searchField_.accessibilityLabel = @"Search tabs";
    [self addSubview:searchField_];

    shortcutHint_ = BroHoverCardLabel(BroUIFont(11.0), 0.35);
    shortcutHint_.stringValue = @"⇧⌘A";
    [shortcutHint_ sizeToFit];
    [self addSubview:shortcutHint_];

    separator_ = [[NSView alloc] initWithFrame:NSZeroRect];
    separator_.wantsLayer = YES;
    separator_.layer.backgroundColor =
        [NSColor colorWithWhite:1.0 alpha:kWindowBorderAlpha].CGColor;
    [self addSubview:separator_];

    listView_ = [[BroTabSearchListView alloc] initWithFrame:NSZeroRect];
    scrollView_ = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView_.drawsBackground = NO;
    scrollView_.borderType = NSNoBorder;
    scrollView_.hasVerticalScroller = YES;
    scrollView_.hasHorizontalScroller = NO;
    scrollView_.scrollerStyle = NSScrollerStyleOverlay;
    scrollView_.automaticallyAdjustsContentInsets = NO;
    scrollView_.documentView = listView_;
    [self addSubview:scrollView_];
  }
  return self;
}

- (void)prepareForDisplay {
  searchField_.stringValue = @"";
  [self reloadWithFilter:@""];
}

- (void)focusSearchField {
  [self.window makeFirstResponder:searchField_];
}

- (void)restoreFocusIfNeeded {
  NSWindow* window = self.window;
  NSResponder* responder = window.firstResponder;
  if ([responder isKindOfClass:[NSText class]] &&
      ((NSText*)responder).delegate == (id)searchField_) {
    [window makeFirstResponder:nil];
  }
}

- (NSString*)displayTitleForTab:(BroTabView*)tab {
  if (tab.pageTitle.length > 0) {
    return tab.pageTitle;
  }
  if (!BroURLIsBlank(tab.tabURL)) {
    return BroDisplayHostForURL(tab.tabURL);
  }
  return kBroBlankTabTitle;
}

// Rebuilds the row list from the live tab strip and the closed-tab history.
// The list is small (tabs + ≤10 closed), so a full rebuild per keystroke is
// simpler than diffing and imperceptible.
- (void)reloadWithFilter:(NSString*)query {
  for (NSView* subview in [listView_.subviews copy]) {
    [subview removeFromSuperview];
  }
  [rows_ removeAllObjects];
  selectedIndex_ = -1;

  NSString* needle =
      [query stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceCharacterSet]].lowercaseString
          ?: @"";
  BOOL (^matches)(NSString*, NSString*) = ^BOOL(NSString* title, NSString* url) {
    if (needle.length == 0) {
      return YES;
    }
    return (title.length > 0 &&
            [title.lowercaseString containsString:needle]) ||
           (url.length > 0 && [url.lowercaseString containsString:needle]);
  };

  NSMutableArray<BroTabView*>* openTabs = [NSMutableArray array];
  for (BroTabView* tab in g_tab_bar.tabs) {
    if (matches([self displayTitleForTab:tab], tab.tabURL)) {
      [openTabs addObject:tab];
    }
  }
  NSMutableArray<BroClosedTabEntry*>* closedTabs = [NSMutableArray array];
  for (BroClosedTabEntry* entry in [BroClosedTabsList() reverseObjectEnumerator]) {
    if (matches(entry.title, entry.url)) {
      [closedTabs addObject:entry];
    }
  }

  const CGFloat rowWidth = kTabSearchPanelWidth - kTabSearchPadX * 2;
  CGFloat y = 4.0;  // flipped list: grows downward

  NSTextField* (^addHeader)(NSString*, CGFloat) =
      ^NSTextField*(NSString* title, CGFloat headerY) {
        NSTextField* header = BroHoverCardLabel(BroUIFontBold(11.0), 0.4);
        header.stringValue = title;
        header.frame = NSMakeRect(kTabSearchPadX + 6.0, headerY + 7.0,
                                  rowWidth - 12.0, 14.0);
        [listView_ addSubview:header];
        return header;
      };

  if (openTabs.count > 0) {
    addHeader(@"Open Tabs", y);
    y += kTabSearchHeaderHeight;
    for (BroTabView* tab in openTabs) {
      BroTabSearchRow* row = [[BroTabSearchRow alloc]
          initWithFrame:NSMakeRect(kTabSearchPadX, y, rowWidth,
                                   kTabSearchRowHeight)];
      row.browserId = tab.browserId;
      [row setTitle:[self displayTitleForTab:tab]];
      [row adoptFaviconFrom:tab.faviconView];
      row.target = self;
      row.action = @selector(rowClicked:);
      [listView_ addSubview:row];
      [rows_ addObject:row];
      y += kTabSearchRowHeight + 2.0;
    }
  }

  if (closedTabs.count > 0) {
    if (openTabs.count > 0) {
      y += 6.0;  // gap between sections
    }
    addHeader(@"Recently Closed", y);
    y += kTabSearchHeaderHeight;
    for (BroClosedTabEntry* entry in closedTabs) {
      BroTabSearchRow* row = [[BroTabSearchRow alloc]
          initWithFrame:NSMakeRect(kTabSearchPadX, y, rowWidth,
                                   kTabSearchRowHeight)];
      row.closedEntry = entry;
      [row setTitle:entry.title.length > 0
                        ? entry.title
                        : BroDisplayHostForURL(entry.url)];
      [row setFaviconURLString:entry.faviconURL];
      row.target = self;
      row.action = @selector(rowClicked:);
      [listView_ addSubview:row];
      [rows_ addObject:row];
      y += kTabSearchRowHeight + 2.0;
    }
  }

  if (rows_.count == 0) {
    NSTextField* empty = BroHoverCardLabel(BroUIFont(12.0), 0.45);
    empty.stringValue = @"No matching tabs";
    empty.alignment = NSTextAlignmentCenter;
    empty.frame = NSMakeRect(kTabSearchPadX, y + 10.0, rowWidth, 16.0);
    [listView_ addSubview:empty];
    y += 36.0;
  }
  y += 4.0;  // bottom padding inside the list

  CGFloat listHeight = MIN(y, kTabSearchListMaxHeight);
  listView_.frame = NSMakeRect(0, 0, kTabSearchPanelWidth, y);

  // Panel layout, bottom-up (unflipped): list, separator, search row.
  CGFloat height = listHeight + 1.0 + kTabSearchFieldRowHeight;
  [self setFrameSize:NSMakeSize(kTabSearchPanelWidth, height)];
  scrollView_.frame = NSMakeRect(0, 0, kTabSearchPanelWidth, listHeight);
  separator_.frame = NSMakeRect(0, listHeight, kTabSearchPanelWidth, 1.0);

  CGFloat fieldRowY = listHeight + 1.0;
  searchIcon_.frame =
      NSMakeRect(14, fieldRowY + (kTabSearchFieldRowHeight - 15) / 2.0, 15, 15);
  NSSize hintSize = shortcutHint_.frame.size;
  shortcutHint_.frame =
      NSMakeRect(kTabSearchPanelWidth - hintSize.width - 14,
                 fieldRowY + (kTabSearchFieldRowHeight - hintSize.height) / 2.0,
                 hintSize.width, hintSize.height);
  searchField_.frame = NSMakeRect(
      38, fieldRowY + (kTabSearchFieldRowHeight - 18) / 2.0,
      kTabSearchPanelWidth - 38 - hintSize.width - 22, 18.0);

  [listView_ scrollPoint:NSZeroPoint];
  if (rows_.count > 0) {
    [self selectRowAtIndex:0];
  }
  [self repositionInContainer];
}

// Anchored under the tab strip's chevron (falling back to the container's
// right edge), hanging from the top like the hover card. Re-run after every
// reload: filtering changes the height.
- (void)repositionInContainer {
  NSView* container = self.superview;
  if (!container) {
    return;
  }
  NSSize size = self.frame.size;
  CGFloat x = NSMaxX(container.bounds) - size.width - 8.0;
  BroHoverButton* chevron = g_tab_bar.tabSearchButton;
  if (chevron && chevron.window == self.window) {
    NSRect chevronRect =
        [container convertRect:chevron.bounds fromView:chevron];
    x = NSMaxX(chevronRect) - size.width;
  }
  x = MAX(8.0, MIN(x, NSMaxX(container.bounds) - size.width - 8.0));
  CGFloat panelY = NSMaxY(container.bounds) - size.height - 6.0;
  self.frame = NSMakeRect(x, panelY, size.width, size.height);
}

- (void)selectRowAtIndex:(NSInteger)index {
  if (selectedIndex_ >= 0 && selectedIndex_ < (NSInteger)rows_.count) {
    rows_[selectedIndex_].selected = NO;
  }
  selectedIndex_ = index;
  BroTabSearchRow* row = rows_[index];
  row.selected = YES;
  [listView_ scrollRectToVisible:NSInsetRect(row.frame, 0, -4.0)];
}

- (void)moveSelectionBy:(NSInteger)delta {
  NSInteger count = (NSInteger)rows_.count;
  if (count == 0) {
    return;
  }
  NSInteger next =
      selectedIndex_ < 0 ? 0 : (selectedIndex_ + delta + count) % count;
  [self selectRowAtIndex:next];
}

- (void)rowClicked:(BroTabSearchRow*)row {
  [self activateRow:row];
}

- (void)activateRow:(BroTabSearchRow*)row {
  if (row.closedEntry) {
    BroClosedTabEntry* entry = row.closedEntry;
    // Reopening consumes the history entry, mirroring ⇧⌘T.
    BroRemoveClosedTab(entry);
    if (entry.url.length > 0) {
      CreateNewBrowserTabWithURL(std::string([entry.url UTF8String]));
    }
  } else {
    BroHandler* handler = BroHandler::GetInstance();
    if (handler) {
      handler->SetActiveBrowser(row.browserId);
    }
  }
  // Explicit hide: activating the already-active tab fires no tab-change
  // callback, so nothing else would dismiss the panel.
  HideTabSearchPanel();
}

- (void)controlTextDidChange:(NSNotification*)notification {
  [self reloadWithFilter:searchField_.stringValue];
}

- (BOOL)control:(NSControl*)control
               textView:(NSTextView*)textView
    doCommandBySelector:(SEL)commandSelector {
  if (commandSelector == @selector(moveUp:)) {
    [self moveSelectionBy:-1];
    return YES;
  }
  if (commandSelector == @selector(moveDown:)) {
    [self moveSelectionBy:1];
    return YES;
  }
  if (commandSelector == @selector(insertNewline:)) {
    if (selectedIndex_ >= 0 && selectedIndex_ < (NSInteger)rows_.count) {
      [self activateRow:rows_[selectedIndex_]];
    }
    return YES;
  }
  if (commandSelector == @selector(cancelOperation:)) {
    HideTabSearchPanel();
    return YES;
  }
  return NO;
}

@end

#pragma mark - Outside-click dismiss monitor

// Installs a local mouse-down monitor that hides `panel` on any click
// outside both `panel` and its owner button. Sees clicks headed for the
// native CEF views too, which never bubble through the AppKit responder
// chain, so an outside click anywhere in the window dismisses.
//
// `isVisible`, if non-nil, is checked first and short-circuits the rest when
// it returns NO (only the tab search panel needs this extra guard today).
// `ownerButton` is re-evaluated on every event rather than captured once, so
// callers can pass a block reading a global that may not be set yet at
// install time. Letting a click on the (visible) owner button through
// avoids an immediate hide-then-reopen when its own action toggles the
// panel. Returns the monitor token for the caller to store and later remove
// with `-[NSEvent removeMonitor:]`. Declared extern in bro_mac_internal.h.
id BroInstallOutsideDismissMonitor(NSView* panel,
                                    BOOL (^isVisible)(void),
                                    NSView* (^ownerButton)(void),
                                    void (^hide)(void)) {
  return [NSEvent
      addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown |
                                            NSEventMaskRightMouseDown |
                                            NSEventMaskOtherMouseDown)
                                   handler:^NSEvent*(NSEvent* event) {
    if (isVisible && !isVisible()) {
      return event;
    }
    if (event.window != panel.window) {
      hide();
      return event;
    }
    NSPoint inPanel = [panel convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(inPanel, panel.bounds)) {
      return event;
    }
    NSView* owner = ownerButton ? ownerButton() : nil;
    if (owner && !owner.hiddenOrHasHiddenAncestor) {
      NSPoint inOwner = [owner convertPoint:event.locationInWindow fromView:nil];
      if (NSPointInRect(inOwner, owner.bounds)) {
        return event;
      }
    }
    hide();
    return event;  // The click still lands wherever it was aimed.
  }];
}

static BroTabSearchPanel* g_tab_search_panel = nil;
// Local mouse-down monitor while the panel shows; sees clicks headed for the
// native CEF views (which never bubble through the AppKit responder chain)
// so an outside click anywhere in the window dismisses.
static id g_tab_search_click_monitor = nil;

static BOOL TabSearchPanelVisible(void) {
  return g_tab_search_panel && g_tab_search_panel.superview &&
         !g_tab_search_panel.hidden;
}

// HideTabSearchPanel is declared extern in bro_mac_internal.h.
void HideTabSearchPanel(void) {
  if (g_tab_search_click_monitor) {
    [NSEvent removeMonitor:g_tab_search_click_monitor];
    g_tab_search_click_monitor = nil;
  }
  if (!TabSearchPanelVisible()) {
    return;
  }
  [g_tab_search_panel restoreFocusIfNeeded];
  g_tab_search_panel.hidden = YES;
}

static void ShowTabSearchPanel(void) {
  NSView* container = BroBrowserContainerView();
  if (!container) {
    return;
  }
  if (!g_tab_search_panel) {
    g_tab_search_panel = [[BroTabSearchPanel alloc] initWithFrame:NSZeroRect];
  }
  // Re-add last on every show so it composites above the CEF views (see
  // showHoverCardForTab:).
  [g_tab_search_panel removeFromSuperview];
  [container addSubview:g_tab_search_panel];
  [g_tab_search_panel prepareForDisplay];
  g_tab_search_panel.hidden = NO;
  [g_tab_search_panel focusSearchField];

  if (!g_tab_search_click_monitor) {
    g_tab_search_click_monitor = BroInstallOutsideDismissMonitor(
        g_tab_search_panel,
        ^BOOL{ return TabSearchPanelVisible(); },
        ^NSView*{ return g_tab_bar.tabSearchButton; },
        ^{ HideTabSearchPanel(); });
  }
}

// ToggleTabSearchPanel is declared extern in bro_mac_internal.h.
void ToggleTabSearchPanel(void) {
  if (TabSearchPanelVisible()) {
    HideTabSearchPanel();
  } else {
    ShowTabSearchPanel();
  }
}

// Releases the retained panel when the main window is torn down; the next
// show rebuilds it fresh. Distinct from HideTabSearchPanel, which keeps it
// around (hidden) for reuse. Declared extern in bro_mac_internal.h.
void TeardownTabSearchPanel(void) {
  [g_tab_search_panel removeFromSuperview];
  g_tab_search_panel = nil;
}
