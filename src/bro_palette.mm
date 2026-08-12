// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The command palette (⌘K, or ⇧⌘A / the tab strip's chevron for the
// tabs-only scope): a centered floating panel with a search field over one
// mixed, fuzzy-filtered list — open tabs, recently closed tabs, app
// commands (derived from the main menu), browsing history, and a pinned
// "search the web / go to URL" fallback row. Same overlay recipe as the
// downloads popover: hand-rolled, re-added last to the browser container on
// every show, retained and hidden rather than destroyed.

#include "bro_handler.h"
#import "bro_mac_internal.h"
#import "bro_closed_tabs.h"
#import "bro_history.h"
#import "bro_motion.h"
#import "radix_icons.h"

#include <string>

#pragma mark - Layout constants

static const CGFloat kPaletteWidth = 560.0;
static const CGFloat kPaletteRowHeight = 40.0;
static const CGFloat kPaletteHeaderHeight = 24.0;
// The list scrolls past this; the search row above never scrolls away.
static const CGFloat kPaletteListMaxHeight = 400.0;
static const CGFloat kPaletteFieldRowHeight = 48.0;
static const CGFloat kPalettePadX = 8.0;
// Distance from the top of the browser container to the panel's top edge,
// which stays fixed while filtering changes the height below it.
static const CGFloat kPaletteTopOffset = 48.0;

// Per-section result caps while a query is active. Tabs are never capped:
// every open tab that matches is reachable.
static const NSUInteger kPaletteMaxClosed = 5;
static const NSUInteger kPaletteMaxCommands = 6;
static const NSUInteger kPaletteMaxHistory = 8;
// Tighter history cap for the browse state shown before any typing.
static const NSUInteger kPaletteMaxHistoryEmptyQuery = 5;

#pragma mark - Fuzzy matcher

// Lowercased UTF-16 code units for the matcher. Built once per item at
// snapshot time so per-keystroke scoring never touches NSString.
static std::u16string BroLowercaseUTF16(NSString* string) {
  NSString* lower = string.lowercaseString;
  std::u16string out;
  out.resize(lower.length);
  if (!out.empty()) {
    [lower getCharacters:reinterpret_cast<unichar*>(&out[0])
                   range:NSMakeRange(0, lower.length)];
  }
  return out;
}

static inline bool BroIsWordSeparator(char16_t c) {
  return c == u' ' || c == u'/' || c == u'.' || c == u'-' || c == u'_' ||
         c == u':';
}

// Case-insensitive subsequence match of |needle| in |haystack| (both
// pre-lowercased). Greedy single forward pass: at these string lengths a
// full alignment search (Smith-Waterman style) rarely ranks differently and
// costs far more. Returns false on a miss; on a hit writes a score that
// rewards start-of-string and word-boundary hits and consecutive runs, and
// mildly penalizes gaps.
static bool BroFuzzyMatch(const std::u16string& needle,
                          const std::u16string& haystack,
                          double* outScore) {
  if (needle.empty()) {
    *outScore = 0.0;
    return true;
  }
  double score = 0.0;
  double gapPenalty = 0.0;
  double leadPenalty = 0.0;
  size_t searchFrom = 0;
  size_t prevMatch = std::u16string::npos;
  for (char16_t c : needle) {
    size_t found = haystack.find(c, searchFrom);
    if (found == std::u16string::npos) {
      return false;
    }
    score += 1.0;
    if (found == 0) {
      score += 8.0;
    } else if (BroIsWordSeparator(haystack[found - 1])) {
      score += 6.0;
    }
    if (prevMatch == std::u16string::npos) {
      leadPenalty = 0.02 * (double)found;
    } else if (found == prevMatch + 1) {
      score += 5.0;
    } else {
      gapPenalty += 0.05 * (double)(found - prevMatch - 1);
    }
    prevMatch = found;
    searchFrom = found + 1;
  }
  score -= MIN(gapPenalty, 6.0);
  score -= MIN(leadPenalty, 6.0);
  *outScore = score;
  return true;
}

#pragma mark - BroPaletteItem

typedef NS_ENUM(NSInteger, BroPaletteItemKind) {
  BroPaletteItemTab,
  BroPaletteItemClosedTab,
  BroPaletteItemCommand,
  BroPaletteItemHistory,
  BroPaletteItemFallback,
};

// One palette candidate. Snapshotted on show; keystrokes only re-score and
// re-sort, so the haystacks are cached lowercased UTF-16 built exactly once.
@interface BroPaletteItem : NSObject {
 @public
  std::u16string titleHaystack_;
  std::u16string urlHaystack_;  // empty for commands
}
@property (nonatomic, assign) BroPaletteItemKind kind;
@property (nonatomic, copy) NSString* title;
@property (nonatomic, copy) NSString* subtitle;  // URL host, or ⌘-hint
// Match score plus the item's constant boost; set by scoring each keystroke.
@property (nonatomic, assign) double score;
// Constant part of the score: kind boost plus (for history) recency and
// visit-count bonuses. Computed once at snapshot time.
@property (nonatomic, assign) double boost;
// Payloads — exactly one is meaningful per kind.
@property (nonatomic, assign) int browserId;                 // tab
@property (nonatomic, strong) BroClosedTabEntry* closedEntry;
@property (nonatomic, strong) NSMenuItem* menuItem;          // command
@property (nonatomic, copy) NSString* historyURL;
@property (nonatomic, copy) NSString* fallbackQuery;
// Icon: a static template icon, a favicon URL to fetch, or a live pill's
// image view to copy from. At most one is set.
@property (nonatomic, strong) NSImage* icon;
@property (nonatomic, copy) NSString* faviconURL;
@property (nonatomic, weak) NSImageView* adoptFaviconFrom;
@end

@implementation BroPaletteItem
- (instancetype)init {
  self = [super init];
  if (self) {
    _browserId = -1;
  }
  return self;
}

- (void)cacheHaystacksWithURL:(NSString*)url {
  titleHaystack_ = BroLowercaseUTF16(_title);
  urlHaystack_ = BroLowercaseUTF16(url);
}
@end

// Scores |item| against |needle|, writing the combined score. Returns false
// when neither the title nor the URL matches. The URL match is discounted so
// a title hit of equal quality wins.
static bool BroPaletteScoreItem(BroPaletteItem* item,
                                const std::u16string& needle) {
  double titleScore = 0.0;
  double urlScore = 0.0;
  bool titleHit = BroFuzzyMatch(needle, item->titleHaystack_, &titleScore);
  bool urlHit = !item->urlHaystack_.empty() &&
                BroFuzzyMatch(needle, item->urlHaystack_, &urlScore);
  if (!titleHit && !urlHit) {
    return false;
  }
  double match = MAX(titleHit ? titleScore : -HUGE_VAL,
                     urlHit ? 0.9 * urlScore : -HUGE_VAL);
  item.score = match + item.boost;
  return true;
}

#pragma mark - Snapshot builders

static NSString* BroPaletteTabTitle(BroTabView* tab) {
  if (tab.pageTitle.length > 0) {
    return tab.pageTitle;
  }
  if (!BroURLIsBlank(tab.tabURL)) {
    return BroDisplayHostForURL(tab.tabURL);
  }
  return kBroBlankTabTitle;
}

static NSArray<BroPaletteItem*>* BroPaletteTabItems(void) {
  NSMutableArray<BroPaletteItem*>* items = [NSMutableArray array];
  for (BroTabView* tab in g_tab_bar.tabs) {
    BroPaletteItem* item = [[BroPaletteItem alloc] init];
    item.kind = BroPaletteItemTab;
    item.title = BroPaletteTabTitle(tab);
    item.subtitle = BroURLIsBlank(tab.tabURL)
                        ? @""
                        : BroDisplayHostForURL(tab.tabURL);
    item.browserId = tab.browserId;
    item.adoptFaviconFrom = tab.faviconView;
    item.boost = 100.0;
    [item cacheHaystacksWithURL:tab.tabURL];
    [items addObject:item];
  }
  return items;
}

static NSArray<BroPaletteItem*>* BroPaletteClosedItems(void) {
  NSMutableArray<BroPaletteItem*>* items = [NSMutableArray array];
  for (BroClosedTabEntry* entry in
       [BroClosedTabsList() reverseObjectEnumerator]) {  // newest first
    BroPaletteItem* item = [[BroPaletteItem alloc] init];
    item.kind = BroPaletteItemClosedTab;
    item.title = entry.title.length > 0 ? entry.title
                                        : BroDisplayHostForURL(entry.url);
    item.subtitle = BroDisplayHostForURL(entry.url);
    item.closedEntry = entry;
    item.faviconURL = entry.faviconURL;
    item.boost = 60.0;
    [item cacheHaystacksWithURL:entry.url];
    [items addObject:item];
  }
  return items;
}

// Selectors whose menu items make no sense as palette commands: app/window
// bookkeeping, text-editing actions that target whatever field is focused,
// tab switching (the tabs section already covers it), the History menu's
// dynamic URL tail (the history section covers it), and the palette's own
// launchers.
static NSSet<NSString*>* BroPaletteExcludedSelectors(void) {
  static NSSet<NSString*>* excluded = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    excluded = [NSSet setWithArray:@[
      @"terminate:", @"orderFrontStandardAboutPanel:",
      @"performMiniaturize:", @"performZoom:",
      @"undo:", @"redo:", @"cut:", @"copy:", @"paste:", @"selectAll:",
      // AppKit injects these into the Edit menu automatically.
      @"startDictation:", @"orderFrontCharacterPalette:",
      @"selectTabAtIndex:", @"selectNextTab:", @"selectPreviousTab:",
      @"historyItemSelected:",
      @"showCommandPalette:", @"showTabSearch:",
    ]];
  });
  return excluded;
}

static NSImage* BroPaletteCommandIcon(SEL action) {
  RadixIcon icon = RadixIconMagnifyingGlass;
  if (action == @selector(newTab:)) {
    icon = RadixIconPlus;
  } else if (action == @selector(showFindBar:) ||
             action == @selector(findNextInPage:) ||
             action == @selector(findPreviousInPage:)) {
    icon = RadixIconMagnifyingGlass;
  } else if (action == @selector(closeTab:)) {
    icon = RadixIconCross2;
  } else if (action == @selector(reloadPage:) ||
             action == @selector(hardReload:)) {
    icon = RadixIconReload;
  } else if (action == @selector(goBack:)) {
    icon = RadixIconArrowLeft;
  } else if (action == @selector(goForward:)) {
    icon = RadixIconArrowRight;
  } else if (action == @selector(toggleSplitScreen:)) {
    icon = RadixIconViewVertical;
  } else if (action == @selector(togglePinActiveTab:)) {
    icon = RadixIconDrawingPin;
  } else if (action == @selector(showDownloads:)) {
    icon = RadixIconDownload;
  } else if (action == @selector(selectDesktopViewport:)) {
    icon = RadixIconDesktop;
  } else if (action == @selector(selectMobileViewport:)) {
    icon = RadixIconMobile;
  } else if (action == @selector(focusAddressBar:)) {
    icon = RadixIconGlobe;
  }
  return RadixIconImage(icon, 15);
}

// "⇧⌘A"-style display string for a menu item's key equivalent.
static NSString* BroPaletteKeyHint(NSMenuItem* item) {
  if (item.keyEquivalent.length == 0) {
    return @"";
  }
  NSMutableString* hint = [NSMutableString string];
  NSEventModifierFlags mask = item.keyEquivalentModifierMask;
  if (mask & NSEventModifierFlagControl) [hint appendString:@"⌃"];
  if (mask & NSEventModifierFlagOption) [hint appendString:@"⌥"];
  if (mask & NSEventModifierFlagShift) [hint appendString:@"⇧"];
  if (mask & NSEventModifierFlagCommand) [hint appendString:@"⌘"];
  [hint appendString:item.keyEquivalent.uppercaseString];
  return hint;
}

static void BroPaletteCollectCommands(NSMenu* menu,
                                      NSMutableArray<BroPaletteItem*>* out) {
  for (NSMenuItem* menuItem in menu.itemArray) {
    if (menuItem.submenu) {
      BroPaletteCollectCommands(menuItem.submenu, out);
      continue;
    }
    if (menuItem.separatorItem || menuItem.hidden || !menuItem.action) {
      continue;
    }
    if ([BroPaletteExcludedSelectors()
            containsObject:NSStringFromSelector(menuItem.action)]) {
      continue;
    }
    id target = [NSApp targetForAction:menuItem.action
                                    to:menuItem.target
                                  from:nil];
    if (!target) {
      continue;
    }
    // validateMenuItem: both filters and retitles in place (Pin/Unpin Tab,
    // Split/Exit Split Screen), so it must run before the title is read. A
    // target without it counts as enabled, matching NSMenu.
    if ([target respondsToSelector:@selector(validateMenuItem:)] &&
        ![target validateMenuItem:menuItem]) {
      continue;
    }
    BroPaletteItem* item = [[BroPaletteItem alloc] init];
    item.kind = BroPaletteItemCommand;
    item.title = menuItem.title;
    item.subtitle = BroPaletteKeyHint(menuItem);
    item.menuItem = menuItem;
    item.icon = BroPaletteCommandIcon(menuItem.action);
    item.boost = 50.0;
    [item cacheHaystacksWithURL:nil];
    [out addObject:item];
  }
}

static NSArray<BroPaletteItem*>* BroPaletteCommandItems(void) {
  NSMutableArray<BroPaletteItem*>* items = [NSMutableArray array];
  NSArray<NSMenuItem*>* topLevel = [NSApp mainMenu].itemArray;
  // Walk the app menu (index 0: Check for Updates…) last so the browse state
  // before typing leads with everyday commands (New Tab, Reload, ...). The
  // Edit menu is skipped wholesale: its native items are all excluded
  // text-editing actions, and macOS injects AutoFill/Dictation/Emoji entries
  // there (in submenus, under private selectors) that make no sense as
  // palette commands.
  for (NSUInteger i = 1; i < topLevel.count; i++) {
    if (topLevel[i].submenu && ![topLevel[i].title isEqualToString:@"Edit"]) {
      BroPaletteCollectCommands(topLevel[i].submenu, items);
    }
  }
  if (topLevel.count > 0 && topLevel[0].submenu) {
    BroPaletteCollectCommands(topLevel[0].submenu, items);
  }
  return items;
}

static NSArray<BroPaletteItem*>* BroPaletteHistoryItems(void) {
  // Skip URLs already offered by the tabs section.
  NSMutableSet<NSString*>* openURLs = [NSMutableSet set];
  for (BroTabView* tab in g_tab_bar.tabs) {
    if (tab.tabURL.length > 0) {
      [openURLs addObject:tab.tabURL];
    }
  }
  NSTimeInterval now = [NSDate date].timeIntervalSince1970;
  NSMutableArray<BroPaletteItem*>* items = [NSMutableArray array];
  for (BroHistoryEntry* entry in
       [BroHistoryEntries() reverseObjectEnumerator]) {  // most recent first
    if ([openURLs containsObject:entry.url]) {
      continue;
    }
    BroPaletteItem* item = [[BroPaletteItem alloc] init];
    item.kind = BroPaletteItemHistory;
    item.title = entry.title.length > 0 ? entry.title
                                        : BroDisplayHostForURL(entry.url);
    item.subtitle = BroDisplayHostForURL(entry.url);
    item.historyURL = entry.url;
    item.faviconURL = entry.faviconURL;
    NSTimeInterval age = now - entry.lastVisit;
    double recency = age < 24 * 3600 ? 15.0 : (age < 7 * 24 * 3600 ? 8.0 : 0.0);
    double frequency = MIN(8.0, 2.0 * log2((double)entry.visitCount + 1.0));
    item.boost = recency + frequency;
    [item cacheHaystacksWithURL:entry.url];
    [items addObject:item];
  }
  return items;
}

#pragma mark - BroPaletteRow

@class BroPaletteRow;

@protocol BroPaletteRowHoverDelegate <NSObject>
- (void)rowHoverBegan:(BroPaletteRow*)row;
@end

// One row: icon/favicon + title, right-aligned dimmed subtitle, hover
// highlight, and a selection highlight driven by the panel's ↑/↓ navigation.
// A plain view rather than BroHoverButton: the hover scale reads wrong on a
// wide list row.
@interface BroPaletteRow : NSView
@property (nonatomic, strong) BroPaletteItem* item;
@property (nonatomic, assign) BOOL selected;
@property (nonatomic, weak) id<BroPaletteRowHoverDelegate> hoverDelegate;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
- (void)configureWithItem:(BroPaletteItem*)item;
@end

@implementation BroPaletteRow {
  NSImageView* iconView_;
  NSTextField* titleLabel_;
  NSTextField* subtitleLabel_;
  // Same guard as BroTabView: a stale fetch must not overwrite the favicon
  // this row was last configured with. Main-thread only.
  NSUInteger faviconGeneration_;
  BOOL focused_;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.cornerRadius =
        BroCornerRadiusForSize(BroControlCornerRadius(), self.bounds.size);
    self.layer.actions = BroLayerTransitionActions();
    self.focusRingType = NSFocusRingTypeNone;

    iconView_ = [[NSImageView alloc]
        initWithFrame:NSMakeRect(12, (frame.size.height - 15) / 2.0, 15, 15)];
    iconView_.imageScaling = NSImageScaleProportionallyUpOrDown;
    iconView_.accessibilityElement = NO;
    [self addSubview:iconView_];

    titleLabel_ = BroHoverCardLabel(BroUIFont(13.0), 0.9);
    [self addSubview:titleLabel_];

    subtitleLabel_ = BroHoverCardLabel(BroUIFont(11.0), 0.4);
    subtitleLabel_.alignment = NSTextAlignmentRight;
    [self addSubview:subtitleLabel_];

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

- (void)showPlaceholderFavicon {
  iconView_.image = RadixIconImage(RadixIconGlobe, 15);
  iconView_.contentTintColor = BroPlaceholderFaviconColor();
}

- (void)setFaviconURLString:(NSString*)urlString {
  NSUInteger generation = ++faviconGeneration_;
  [self showPlaceholderFavicon];
  if (urlString.length == 0) {
    return;
  }
  __weak BroPaletteRow* weakSelf = self;
  BroFetchFaviconGuarded(
      urlString, generation,
      ^BOOL(NSUInteger g) {
        BroPaletteRow* strongSelf = weakSelf;
        return strongSelf && strongSelf->faviconGeneration_ == g;
      },
      ^(NSImage* image) {
        BroPaletteRow* strongSelf = weakSelf;
        strongSelf->iconView_.image = image;
        strongSelf->iconView_.contentTintColor = nil;
      });
}

- (void)configureWithItem:(BroPaletteItem*)item {
  _item = item;
  titleLabel_.stringValue = item.title ?: @"";
  subtitleLabel_.stringValue = item.subtitle ?: @"";
  // Command shortcuts are help, not part of the action's concise name. URL
  // subtitles remain useful context for tab/history results.
  if (item.kind == BroPaletteItemCommand) {
    self.accessibilityLabel = titleLabel_.stringValue;
    self.accessibilityHelp = item.subtitle.length > 0
        ? [NSString stringWithFormat:@"Keyboard shortcut: %@.", item.subtitle]
        : @"Press Return to run this command.";
  } else {
    self.accessibilityLabel =
        item.subtitle.length > 0
            ? [NSString stringWithFormat:@"%@, %@", item.title, item.subtitle]
            : titleLabel_.stringValue;
    self.accessibilityHelp = @"Press Return to activate.";
  }

  faviconGeneration_++;
  if (item.icon) {
    iconView_.image = item.icon;
    iconView_.contentTintColor = [NSColor secondaryLabelColor];
  } else if (item.adoptFaviconFrom.image) {
    iconView_.image = item.adoptFaviconFrom.image;
    iconView_.contentTintColor = item.adoptFaviconFrom.contentTintColor;
  } else if (item.faviconURL.length > 0) {
    [self setFaviconURLString:item.faviconURL];
  } else {
    [self showPlaceholderFavicon];
  }

  // Subtitle gets the width it needs (capped), title truncates around it.
  [subtitleLabel_ sizeToFit];
  CGFloat rowWidth = NSWidth(self.frame);
  CGFloat rowHeight = NSHeight(self.frame);
  CGFloat subtitleWidth = MIN(NSWidth(subtitleLabel_.frame), 200.0);
  subtitleLabel_.frame =
      NSMakeRect(rowWidth - subtitleWidth - 12,
                 (rowHeight - 15) / 2.0, subtitleWidth, 15);
  CGFloat titleX = 38;
  CGFloat titleRightPad = subtitleWidth > 0 ? subtitleWidth + 20 : 12;
  titleLabel_.frame = NSMakeRect(titleX, (rowHeight - 17) / 2.0,
                                 rowWidth - titleX - titleRightPad, 17);
}

- (void)setSelected:(BOOL)selected {
  _selected = selected;
  self.accessibilitySelected = selected;
}

- (void)mouseEntered:(NSEvent*)event {
  [_hoverDelegate rowHoverBegan:self];
}

- (void)mouseExited:(NSEvent*)event {
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
    self.layer.borderColor = BroControlBorderColor().CGColor;
    self.layer.borderWidth = 1.0;
  }
  return ok;
}

- (BOOL)resignFirstResponder {
  BOOL ok = [super resignFirstResponder];
  if (ok) {
    focused_ = NO;
    self.layer.borderWidth = 0.0;
  }
  return ok;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  if (focused_) {
    self.layer.borderColor = BroControlBorderColor().CGColor;
  }
}

- (void)keyDown:(NSEvent*)event {
  NSString* characters = event.charactersIgnoringModifiers;
  unichar key = characters.length > 0 ? [characters characterAtIndex:0] : 0;
  if (key == ' ' || key == '\r' || key == NSEnterCharacter) {
    [NSApp sendAction:_action to:_target from:self];
    return;
  }
  [super keyDown:event];
}

- (BOOL)accessibilityPerformPress {
  [NSApp sendAction:_action to:_target from:self];
  return YES;
}

@end

// Flipped host for the row list so rows stack top-down in the scroll view.
@interface BroPaletteListView : NSView
@end

@implementation BroPaletteListView
- (BOOL)isFlipped {
  return YES;
}
@end

#pragma mark - BroCommandPalette

// A section is one scored, capped slice of the snapshot rendered under a
// header. Sections are re-ranked per keystroke by their best item.
@interface BroCommandPalette
    : NSView <NSTextFieldDelegate, BroPaletteRowHoverDelegate>
// Rebuilds the source snapshot for |scope|, clears the query, reloads, and
// positions the panel; the caller unhides it and focuses the field.
- (void)prepareForDisplayWithScope:(BroPaletteScope)scope;
- (void)focusSearchField;
// Hands keyboard focus back if the search field's editor still holds it.
- (void)restoreFocusIfNeeded;
@end

@implementation BroCommandPalette {
  NSView* contentHost_;
  NSTextField* searchField_;
  NSImageView* searchIcon_;
  NSTextField* shortcutHint_;
  NSView* separator_;
  NSScrollView* scrollView_;
  BroPaletteListView* listView_;
  NSMutableArray<BroPaletteRow*>* rows_;
  NSInteger selectedIndex_;
  BroHoverHighlightGroup* rowHighlightGroup_;
  BroPaletteScope scope_;
  // Source snapshots, rebuilt on every show (see prepareForDisplayWithScope:).
  NSArray<BroPaletteItem*>* tabItems_;
  NSArray<BroPaletteItem*>* closedItems_;
  NSArray<BroPaletteItem*>* commandItems_;
  NSArray<BroPaletteItem*>* historyItems_;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  separator_.layer.backgroundColor = [NSColor separatorColor].CGColor;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    rows_ = [NSMutableArray array];
    selectedIndex_ = -1;

    self.accessibilityRole = NSAccessibilityGroupRole;
    self.accessibilityLabel = @"Command palette";

    self.wantsLayer = YES;
    self.layer.cornerRadius =
        BroCornerRadiusForSize(BroSurfaceCornerRadius(), self.bounds.size);
    BroApplyElevation(self, BroElevationPanel);
    contentHost_ = BroInstallGlassSurface(self, self.layer.cornerRadius);

    searchIcon_ = [[NSImageView alloc] initWithFrame:NSZeroRect];
    searchIcon_.image = RadixIconImage(RadixIconMagnifyingGlass, 15);
    searchIcon_.contentTintColor = [NSColor secondaryLabelColor];
    searchIcon_.accessibilityElement = NO;
    [contentHost_ addSubview:searchIcon_];

    searchField_ = [[NSTextField alloc] initWithFrame:NSZeroRect];
    searchField_.font = BroUIFont(13.0);
    searchField_.textColor = [NSColor labelColor];
    searchField_.bordered = NO;
    searchField_.bezeled = NO;
    searchField_.drawsBackground = NO;
    searchField_.focusRingType = NSFocusRingTypeNone;
    searchField_.cell.usesSingleLineMode = YES;
    searchField_.cell.scrollable = YES;
    searchField_.delegate = self;
    [contentHost_ addSubview:searchField_];

    shortcutHint_ = BroHoverCardLabel(BroUIFont(11.0), 0.35);
    [contentHost_ addSubview:shortcutHint_];

    separator_ = [[NSView alloc] initWithFrame:NSZeroRect];
    separator_.wantsLayer = YES;
    separator_.layer.backgroundColor = [NSColor separatorColor].CGColor;
    [contentHost_ addSubview:separator_];

    listView_ = [[BroPaletteListView alloc] initWithFrame:NSZeroRect];
    scrollView_ = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView_.drawsBackground = NO;
    scrollView_.borderType = NSNoBorder;
    scrollView_.hasVerticalScroller = YES;
    scrollView_.hasHorizontalScroller = NO;
    scrollView_.scrollerStyle = NSScrollerStyleOverlay;
    scrollView_.automaticallyAdjustsContentInsets = NO;
    scrollView_.documentView = listView_;
    [contentHost_ addSubview:scrollView_];
    rowHighlightGroup_ =
        [[BroHoverHighlightGroup alloc] initWithContainerView:listView_];
  }
  return self;
}

- (void)prepareForDisplayWithScope:(BroPaletteScope)scope {
  scope_ = scope;
  BOOL tabsOnly = scope == BroPaletteScopeTabs;

  NSString* placeholder =
      tabsOnly ? @"Search tabs" : @"Search tabs, history, and commands…";
  searchField_.placeholderAttributedString = [[NSAttributedString alloc]
      initWithString:placeholder
          attributes:@{
            NSFontAttributeName : BroUIFont(13.0),
            NSForegroundColorAttributeName : [NSColor tertiaryLabelColor],
          }];
  searchField_.accessibilityLabel = placeholder;
  shortcutHint_.stringValue = tabsOnly ? @"⇧⌘A" : @"⌘K";
  [shortcutHint_ sizeToFit];

  tabItems_ = BroPaletteTabItems();
  closedItems_ = BroPaletteClosedItems();
  commandItems_ = tabsOnly ? @[] : BroPaletteCommandItems();
  historyItems_ = tabsOnly ? @[] : BroPaletteHistoryItems();

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

// Scores |source| against |needle| and returns the survivors sorted by
// descending score, capped at |cap|. Ties keep source order (recency), so
// the sort must be stable.
static NSArray<BroPaletteItem*>* BroPaletteFilterSection(
    NSArray<BroPaletteItem*>* source,
    const std::u16string& needle,
    NSUInteger cap) {
  NSMutableArray<BroPaletteItem*>* matched = [NSMutableArray array];
  for (BroPaletteItem* item in source) {
    if (BroPaletteScoreItem(item, needle)) {
      [matched addObject:item];
    }
  }
  NSArray<BroPaletteItem*>* sorted = [matched
      sortedArrayWithOptions:NSSortStable
             usingComparator:^NSComparisonResult(BroPaletteItem* a,
                                                 BroPaletteItem* b) {
               if (a.score > b.score) return NSOrderedAscending;
               if (a.score < b.score) return NSOrderedDescending;
               return NSOrderedSame;
             }];
  if (sorted.count > cap) {
    sorted = [sorted subarrayWithRange:NSMakeRange(0, cap)];
  }
  return sorted;
}

// Rebuilds the row list from the snapshot. The candidate pool can be large
// (history is capped at 3000 entries) but scoring is flat char16 scans and
// only the few surviving rows become views, so a full rebuild per keystroke
// stays imperceptible.
- (void)reloadWithFilter:(NSString*)query {
  [rowHighlightGroup_ dismissImmediately];
  for (NSView* subview in [listView_.subviews copy]) {
    [subview removeFromSuperview];
  }
  [rows_ removeAllObjects];
  selectedIndex_ = -1;

  NSString* trimmed =
      [query stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceCharacterSet]] ?: @"";
  BOOL browsing = trimmed.length == 0;
  std::u16string needle = BroLowercaseUTF16(trimmed);

  // Assemble sections: fixed composition while browsing, scored + re-ranked
  // by each section's best item once a query is typed.
  NSMutableArray<NSDictionary*>* sections = [NSMutableArray array];
  void (^addSection)(NSString*, NSArray<BroPaletteItem*>*) =
      ^(NSString* title, NSArray<BroPaletteItem*>* items) {
        if (items.count > 0) {
          [sections addObject:@{@"title" : title, @"items" : items}];
        }
      };
  if (browsing) {
    for (BroPaletteItem* item in tabItems_) item.score = 0;
    addSection(@"Open Tabs", tabItems_);
    addSection(@"Recently Closed",
               closedItems_.count > kPaletteMaxClosed
                   ? [closedItems_
                         subarrayWithRange:NSMakeRange(0, kPaletteMaxClosed)]
                   : closedItems_);
    addSection(@"Commands",
               commandItems_.count > kPaletteMaxCommands
                   ? [commandItems_
                         subarrayWithRange:NSMakeRange(0, kPaletteMaxCommands)]
                   : commandItems_);
    addSection(@"History",
               historyItems_.count > kPaletteMaxHistoryEmptyQuery
                   ? [historyItems_ subarrayWithRange:
                                        NSMakeRange(0,
                                                    kPaletteMaxHistoryEmptyQuery)]
                   : historyItems_);
  } else {
    addSection(@"Open Tabs",
               BroPaletteFilterSection(tabItems_, needle, NSUIntegerMax));
    addSection(@"Recently Closed",
               BroPaletteFilterSection(closedItems_, needle,
                                       kPaletteMaxClosed));
    addSection(@"Commands",
               BroPaletteFilterSection(commandItems_, needle,
                                       kPaletteMaxCommands));
    addSection(@"History",
               BroPaletteFilterSection(historyItems_, needle,
                                       kPaletteMaxHistory));
    [sections sortWithOptions:NSSortStable
              usingComparator:^NSComparisonResult(NSDictionary* a,
                                                  NSDictionary* b) {
                double bestA = [a[@"items"][0] score];
                double bestB = [b[@"items"][0] score];
                if (bestA > bestB) return NSOrderedAscending;
                if (bestA < bestB) return NSOrderedDescending;
                return NSOrderedSame;
              }];
  }

  // The fallback row makes the palette an omnibox: whatever was typed can
  // always be searched or navigated to. Tabs scope keeps the old tab-search
  // behavior and skips it.
  BroPaletteItem* fallback = nil;
  if (!browsing && scope_ == BroPaletteScopeAll) {
    NSString* resolved = BroResolveQueryToURL(trimmed);
    fallback = [[BroPaletteItem alloc] init];
    fallback.kind = BroPaletteItemFallback;
    fallback.fallbackQuery = trimmed;
    if ([resolved hasPrefix:@"https://www.google.com/search?q="]) {
      fallback.title =
          [NSString stringWithFormat:@"Search the web for “%@”", trimmed];
      fallback.icon = RadixIconImage(RadixIconMagnifyingGlass, 15);
    } else {
      fallback.title = [NSString stringWithFormat:@"Go to %@", resolved];
      fallback.icon = RadixIconImage(RadixIconGlobe, 15);
    }
    fallback.subtitle = @"";
  }

  const CGFloat rowWidth = kPaletteWidth - kPalettePadX * 2;
  CGFloat y = 4.0;  // flipped list: grows downward

  NSTextField* (^addHeader)(NSString*, CGFloat) =
      ^NSTextField*(NSString* title, CGFloat headerY) {
        NSTextField* header = BroHoverCardLabel(BroUIFontBold(11.0), 0.4);
        header.stringValue = title;
        header.frame = NSMakeRect(kPalettePadX + 6.0, headerY + 7.0,
                                  rowWidth - 12.0, 14.0);
        [listView_ addSubview:header];
        return header;
      };
  BroPaletteRow* (^addRow)(BroPaletteItem*, CGFloat) =
      ^BroPaletteRow*(BroPaletteItem* item, CGFloat rowY) {
        BroPaletteRow* row = [[BroPaletteRow alloc]
            initWithFrame:NSMakeRect(kPalettePadX, rowY, rowWidth,
                                     kPaletteRowHeight)];
        [row configureWithItem:item];
        row.target = self;
        row.action = @selector(rowClicked:);
        row.hoverDelegate = self;
        [listView_ addSubview:row];
        [rows_ addObject:row];
        return row;
      };

  for (NSDictionary* section in sections) {
    if (y > 4.0) {
      y += 6.0;  // gap between sections
    }
    addHeader(section[@"title"], y);
    y += kPaletteHeaderHeight;
    for (BroPaletteItem* item in section[@"items"]) {
      addRow(item, y);
      y += kPaletteRowHeight + 2.0;
    }
  }

  if (fallback) {
    if (y > 4.0) {
      y += 6.0;
    }
    addRow(fallback, y);
    y += kPaletteRowHeight + 2.0;
  }

  if (rows_.count == 0) {
    NSTextField* empty = BroHoverCardLabel(BroUIFont(12.0), 0.45);
    empty.stringValue = @"No results";
    empty.alignment = NSTextAlignmentCenter;
    empty.frame = NSMakeRect(kPalettePadX, y + 10.0, rowWidth, 16.0);
    [listView_ addSubview:empty];
    y += 36.0;
  }
  y += 4.0;  // bottom padding inside the list

  // Short windows get a shorter list rather than a clipped panel.
  CGFloat maxList = kPaletteListMaxHeight;
  NSView* container = self.superview;
  if (container) {
    maxList = MIN(maxList, NSHeight(container.bounds) - kPaletteTopOffset -
                               kPaletteFieldRowHeight - 1.0 - 8.0);
  }
  CGFloat listHeight = MIN(y, MAX(maxList, kPaletteRowHeight));
  listView_.frame = NSMakeRect(0, 0, kPaletteWidth, y);

  // Panel layout, bottom-up (unflipped): list, separator, search row.
  CGFloat height = listHeight + 1.0 + kPaletteFieldRowHeight;
  [self setFrameSize:NSMakeSize(kPaletteWidth, height)];
  scrollView_.frame = NSMakeRect(0, 0, kPaletteWidth, listHeight);
  separator_.frame = NSMakeRect(0, listHeight, kPaletteWidth, 1.0);

  CGFloat fieldRowY = listHeight + 1.0;
  searchIcon_.frame =
      NSMakeRect(16, fieldRowY + (kPaletteFieldRowHeight - 15) / 2.0, 15, 15);
  NSSize hintSize = shortcutHint_.frame.size;
  shortcutHint_.frame =
      NSMakeRect(kPaletteWidth - hintSize.width - 16,
                 fieldRowY + (kPaletteFieldRowHeight - hintSize.height) / 2.0,
                 hintSize.width, hintSize.height);
  searchField_.frame = NSMakeRect(
      42, fieldRowY + (kPaletteFieldRowHeight - 18) / 2.0,
      kPaletteWidth - 42 - hintSize.width - 24, 18.0);

  [listView_ scrollPoint:NSZeroPoint];
  if (rows_.count > 0) {
    [self selectRowAtIndex:0 animated:NO];
  }
  [self repositionInContainer];
}

// Horizontally centered in the browser container; the top edge hangs at a
// fixed offset (cmdk-style) so the panel only ever grows downward as
// filtering changes the height. Re-run after every reload.
- (void)repositionInContainer {
  NSView* container = self.superview;
  if (!container) {
    return;
  }
  NSSize size = self.frame.size;
  CGFloat x = MAX(8.0, round((NSWidth(container.bounds) - size.width) / 2.0));
  CGFloat panelY = NSMaxY(container.bounds) - kPaletteTopOffset - size.height;
  self.frame = NSMakeRect(x, panelY, size.width, size.height);
}

- (void)selectRowAtIndex:(NSInteger)index animated:(BOOL)animated {
  if (index < 0 || index >= (NSInteger)rows_.count) {
    return;
  }
  if (selectedIndex_ >= 0 && selectedIndex_ < (NSInteger)rows_.count) {
    rows_[selectedIndex_].selected = NO;
  }
  selectedIndex_ = index;
  BroPaletteRow* row = rows_[index];
  row.selected = YES;
  [listView_ scrollRectToVisible:NSInsetRect(row.frame, 0, -4.0)];
  [rowHighlightGroup_ hoverOnView:row animated:animated];
}

- (void)moveSelectionBy:(NSInteger)delta {
  NSInteger count = (NSInteger)rows_.count;
  if (count == 0) {
    return;
  }
  NSInteger next =
      selectedIndex_ < 0 ? 0 : (selectedIndex_ + delta + count) % count;
  [self selectRowAtIndex:next animated:YES];
  // Keyboard focus stays in the field while ↑/↓/Tab move the selection, so
  // VoiceOver never sees a focus change; announce the selected row instead.
  // Hover-driven selection stays silent — the pointer already says where it
  // is, and announcing every crossed row would chatter.
  BroPaletteRow* row = rows_[next];
  NSAccessibilityPostNotificationWithUserInfo(
      row, NSAccessibilityAnnouncementRequestedNotification, @{
        NSAccessibilityAnnouncementKey : row.accessibilityLabel ?: @"",
        NSAccessibilityPriorityKey : @(NSAccessibilityPriorityHigh),
      });
}

- (void)rowHoverBegan:(BroPaletteRow*)row {
  NSInteger index = [rows_ indexOfObject:row];
  if (index != NSNotFound) {
    [self selectRowAtIndex:index animated:YES];
  }
}

- (void)rowClicked:(BroPaletteRow*)row {
  [self activateRow:row];
}

- (void)activateRow:(BroPaletteRow*)row {
  BroPaletteItem* item = row.item;
  switch (item.kind) {
    case BroPaletteItemTab: {
      BroHandler* handler = BroHandler::GetInstance();
      if (handler) {
        handler->SetActiveBrowser(item.browserId);
      }
      // Explicit hide: activating the already-active tab fires no tab-change
      // callback, so nothing else would dismiss the panel.
      HideCommandPalette();
      break;
    }
    case BroPaletteItemClosedTab: {
      BroClosedTabEntry* entry = item.closedEntry;
      // Reopening consumes the history entry, mirroring ⇧⌘T.
      BroRemoveClosedTab(entry);
      if (entry.url.length > 0) {
        CreateNewBrowserTabWithURL(std::string([entry.url UTF8String]));
      }
      HideCommandPalette();
      break;
    }
    case BroPaletteItemCommand: {
      NSMenuItem* menuItem = item.menuItem;
      HideCommandPalette();
      // Deferred so the palette's focus teardown settles first; actions like
      // Open Location move first responder themselves and must win. The menu
      // item is the sender so tag/representedObject-reading handlers work.
      dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp sendAction:menuItem.action to:menuItem.target from:menuItem];
      });
      break;
    }
    case BroPaletteItemHistory: {
      NSString* url = item.historyURL;
      HideCommandPalette();
      // Loads in the current tab, like the History menu; a new tab would
      // pile up strip clutter for a "take me back there" gesture.
      BroHandler* handler = BroHandler::GetInstance();
      CefRefPtr<CefBrowser> browser = handler ? handler->GetBrowser() : nullptr;
      if (browser) {
        browser->GetMainFrame()->LoadURL([url UTF8String]);
      } else if (url.length > 0) {
        CreateNewBrowserTabWithURL(std::string([url UTF8String]));
      }
      break;
    }
    case BroPaletteItemFallback: {
      NSString* query = item.fallbackQuery;
      HideCommandPalette();
      [g_toolbar navigateToURL:query];
      break;
    }
  }
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
  // Tab cycles items like ↑/↓ (wrapping) while the field keeps focus —
  // Tab must not leave the palette for the window's key-view loop.
  if (commandSelector == @selector(insertTab:)) {
    [self moveSelectionBy:1];
    return YES;
  }
  if (commandSelector == @selector(insertBacktab:)) {
    [self moveSelectionBy:-1];
    return YES;
  }
  if (commandSelector == @selector(insertNewline:)) {
    if (selectedIndex_ >= 0 && selectedIndex_ < (NSInteger)rows_.count) {
      [self activateRow:rows_[selectedIndex_]];
    }
    return YES;
  }
  if (commandSelector == @selector(cancelOperation:)) {
    // Normally the Esc key monitor wins; this is the fallback if it's gone.
    HideCommandPalette();
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
// it returns NO (only the command palette needs this extra guard today).
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

#pragma mark - Palette wiring

static BroCommandPalette* g_command_palette = nil;
// Installed while the palette shows; both removed on hide (a leaked monitor
// would keep re-hiding on every later click / Esc press). The click monitor
// sees clicks headed for the native CEF views, which never bubble through
// the AppKit responder chain; the key monitor catches Esc even when the
// search field has lost first responder.
static id g_palette_click_monitor = nil;
static id g_palette_key_monitor = nil;

static BOOL CommandPaletteVisible(void) {
  return g_command_palette && g_command_palette.superview &&
         !g_command_palette.hidden;
}

// HideCommandPalette is declared extern in bro_mac_internal.h.
void HideCommandPalette(void) {
  // Monitors go first, unconditionally: the visibility check below must
  // never leave one behind.
  if (g_palette_click_monitor) {
    [NSEvent removeMonitor:g_palette_click_monitor];
    g_palette_click_monitor = nil;
  }
  if (g_palette_key_monitor) {
    [NSEvent removeMonitor:g_palette_key_monitor];
    g_palette_key_monitor = nil;
  }
  if (!CommandPaletteVisible()) {
    return;
  }
  [g_command_palette restoreFocusIfNeeded];
  BroOverlayHide(g_command_palette);
}

static void ShowCommandPalette(BroPaletteScope scope) {
  NSView* container = BroBrowserContainerView();
  if (!container) {
    return;
  }
  if (!g_command_palette) {
    g_command_palette = [[BroCommandPalette alloc] initWithFrame:NSZeroRect];
    g_command_palette.hidden = YES;
  }
  // Re-add last on every show so it composites above the CEF views (see
  // showHoverCardForTab:).
  [g_command_palette removeFromSuperview];
  [container addSubview:g_command_palette];
  [g_command_palette prepareForDisplayWithScope:scope];
  BroOverlayShow(g_command_palette);
  [g_command_palette focusSearchField];

  if (!g_palette_click_monitor) {
    g_palette_click_monitor = BroInstallOutsideDismissMonitor(
        g_command_palette,
        ^BOOL{ return CommandPaletteVisible(); },
        ^NSView*{ return g_tab_bar.tabSearchButton; },
        ^{ HideCommandPalette(); });
  }
  if (!g_palette_key_monitor) {
    g_palette_key_monitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent*(NSEvent* event) {
      if (event.keyCode == 53) {  // Esc
        HideCommandPalette();
        return nil;
      }
      return event;
    }];
  }
}

// ToggleCommandPalette is declared extern in bro_mac_internal.h.
void ToggleCommandPalette(BroPaletteScope scope) {
  if (CommandPaletteVisible()) {
    HideCommandPalette();
  } else {
    ShowCommandPalette(scope);
  }
}

// Releases the retained palette when the main window is torn down; the next
// show rebuilds it fresh. Distinct from HideCommandPalette, which keeps it
// around (hidden) for reuse. Declared extern in bro_mac_internal.h.
void TeardownCommandPalette(void) {
  [g_command_palette removeFromSuperview];
  g_command_palette = nil;
}
