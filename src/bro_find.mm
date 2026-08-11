#import "bro_find.h"

#include "bro_handler.h"
#import "bro_mac_internal.h"
#import "bro_motion.h"
#import "radix_icons.h"

@class BroFindBar;

@interface BroFindField : NSTextField
@property(nonatomic, weak) BroFindBar* findBar;
@end

@interface BroFindBar : NSView <NSTextFieldDelegate>
- (void)prepareForDisplay;
- (void)stopFinding;
- (void)findNext:(id)sender;
- (void)findPrevious:(id)sender;
- (void)closeFind:(id)sender;
- (void)keepAboveBrowser;
- (void)updateIdentifier:(int)identifier
                   count:(int)count
                 ordinal:(int)ordinal;
@property(nonatomic, readonly) BOOL hasQuery;
@end

@implementation BroFindField

- (void)keyDown:(NSEvent*)event {
  NSString* chars = event.charactersIgnoringModifiers;
  unichar key = chars.length > 0 ? [chars characterAtIndex:0] : 0;
  if (event.keyCode == 53 || key == 0x1b) {  // Escape
    [self.findBar closeFind:self];
    return;
  }
  if (key == '\r' || key == NSEnterCharacter) {
    if (event.modifierFlags & NSEventModifierFlagShift) {
      [self.findBar findPrevious:self];
    } else {
      [self.findBar findNext:self];
    }
    return;
  }
  [super keyDown:event];
}

@end

@implementation BroFindBar {
  NSView* contentHost_;
  BroFindField* searchField_;
  NSTextField* countLabel_;
  BroHoverHighlightGroup* actionHighlightGroup_;
  __weak NSResponder* previousFirstResponder_;
  int lastFindIdentifier_;
  int lastActiveOrdinal_;
}

static BroHoverButton* BroFindButton(NSRect frame,
                                     NSImage* image,
                                     NSString* label,
                                     NSString* keyEquivalent,
                                     NSEventModifierFlags modifiers,
                                     id target,
                                     SEL action) {
  BroHoverButton* button = [[BroHoverButton alloc] initWithFrame:frame];
  button.bordered = NO;
  button.title = @"";
  button.image = image;
  button.imagePosition = NSImageOnly;
  button.contentTintColor = [NSColor labelColor];
  button.target = target;
  button.action = action;
  [button configureActionLabel:label
                 keyEquivalent:keyEquivalent
                  modifierMask:modifiers];
  return button;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) {
    return nil;
  }

  self.wantsLayer = YES;
  self.layer.cornerRadius =
      BroCornerRadiusForSize(BroSurfaceCornerRadius(), self.bounds.size);
  BroApplyElevation(self, BroElevationPanel);
  contentHost_ = BroInstallGlassSurface(self, self.layer.cornerRadius);
  self.accessibilityElement = YES;
  self.accessibilityRole = NSAccessibilityGroupRole;
  self.accessibilityLabel = @"Find in page";

  const CGFloat centerY = NSMidY(self.bounds);

  NSImageView* searchIcon = [[NSImageView alloc]
      initWithFrame:NSMakeRect(12.0, centerY - 7.5, 15.0, 15.0)];
  searchIcon.image = RadixIconImage(RadixIconMagnifyingGlass, 15.0);
  searchIcon.contentTintColor = [NSColor secondaryLabelColor];
  searchIcon.accessibilityElement = NO;
  [contentHost_ addSubview:searchIcon];

  searchField_ = [[BroFindField alloc]
      initWithFrame:NSMakeRect(35.0, centerY - 9.0, 137.0, 18.0)];
  searchField_.findBar = self;
  searchField_.delegate = self;
  searchField_.font = BroUIFont(13.0);
  searchField_.textColor = [NSColor labelColor];
  searchField_.bordered = NO;
  searchField_.bezeled = NO;
  searchField_.drawsBackground = NO;
  searchField_.focusRingType = NSFocusRingTypeNone;
  searchField_.cell.usesSingleLineMode = YES;
  searchField_.cell.scrollable = YES;
  searchField_.placeholderAttributedString = [[NSAttributedString alloc]
      initWithString:@"Find in page"
          attributes:@{
            NSFontAttributeName : BroUIFont(13.0),
            NSForegroundColorAttributeName : [NSColor tertiaryLabelColor],
          }];
  searchField_.accessibilityLabel = @"Find in page";
  searchField_.accessibilityHelp =
      @"Type search text. Press Return for the next match or Shift-Return for the previous match.";
  [contentHost_ addSubview:searchField_];

  countLabel_ = BroHoverCardLabel(BroUIFont(11.0), 0.55);
  countLabel_.frame = NSMakeRect(178.0, centerY - 9.0, 48.0, 18.0);
  countLabel_.alignment = NSTextAlignmentCenter;
  countLabel_.lineBreakMode = NSLineBreakByClipping;
  countLabel_.accessibilityElement = YES;
  countLabel_.accessibilityLabel = @"No search results yet";
  [contentHost_ addSubview:countLabel_];

  const NSEventModifierFlags command = NSEventModifierFlagCommand;
  BroHoverButton* previous = BroFindButton(
      NSMakeRect(230.0, centerY - 14.0, 28.0, 28.0),
      RadixIconImage(RadixIconArrowUp, 15.0), @"Find Previous", @"g",
      command | NSEventModifierFlagShift, self, @selector(findPrevious:));
  [contentHost_ addSubview:previous];

  BroHoverButton* next = BroFindButton(
      NSMakeRect(262.0, centerY - 14.0, 28.0, 28.0),
      RadixIconImage(RadixIconArrowDown, 15.0), @"Find Next", @"g", command,
      self, @selector(findNext:));
  [contentHost_ addSubview:next];

  BroHoverButton* close = BroFindButton(
      NSMakeRect(294.0, centerY - 14.0, 28.0, 28.0),
      RadixIconImage(RadixIconCross2, 13.0), @"Close Find Bar", @"\e", 0,
      self, @selector(closeFind:));
  [contentHost_ addSubview:close];

  actionHighlightGroup_ =
      [[BroHoverHighlightGroup alloc] initWithContainerView:contentHost_];
  previous.highlightGroup = actionHighlightGroup_;
  next.highlightGroup = actionHighlightGroup_;
  close.highlightGroup = actionHighlightGroup_;

  return self;
}

- (BOOL)hasQuery {
  return searchField_.stringValue.length > 0;
}

- (void)prepareForDisplay {
  previousFirstResponder_ = self.window.firstResponder;
  countLabel_.stringValue = @"";
  countLabel_.accessibilityLabel = @"Searching";
  [self.window makeFirstResponder:searchField_];
  [searchField_ selectText:nil];
  if (self.hasQuery) {
    [self startNewSearch];
  }
}

- (CefRefPtr<CefBrowser>)activeBrowser {
  BroHandler* handler = BroHandler::GetInstance();
  return handler ? handler->GetBrowser() : nullptr;
}

- (void)keepAboveBrowser {
  // Windowed CEF operations can raise the native browser view both when a
  // search starts and when results arrive. Keep the overlay above that child
  // view throughout the find session without disturbing its live editor.
  if (self.superview) {
    [self.superview addSubview:self positioned:NSWindowAbove relativeTo:nil];
  }
}

- (void)startNewSearch {
  CefRefPtr<CefBrowser> browser = [self activeBrowser];
  if (!browser) {
    return;
  }
  NSString* query = searchField_.stringValue;
  if (query.length == 0) {
    browser->GetHost()->StopFinding(true);
    countLabel_.stringValue = @"";
    countLabel_.accessibilityLabel = @"No search query";
    return;
  }
  countLabel_.stringValue = @"…";
  countLabel_.accessibilityLabel = @"Searching";
  lastActiveOrdinal_ = 0;
  browser->GetHost()->Find([query UTF8String], true, false, false);
  [self keepAboveBrowser];
}

- (void)findInDirection:(BOOL)forward {
  if (!self.hasQuery) {
    [self.window makeFirstResponder:searchField_];
    return;
  }
  CefRefPtr<CefBrowser> browser = [self activeBrowser];
  if (browser) {
    browser->GetHost()->Find([searchField_.stringValue UTF8String], forward,
                             false, true);
    [self keepAboveBrowser];
    // Navigation can move focus into the browser while it scrolls the active
    // match; hand it back so the query remains immediately editable.
    [self.window makeFirstResponder:searchField_];
  }
}

- (void)findNext:(id)sender {
  [self findInDirection:YES];
}

- (void)findPrevious:(id)sender {
  [self findInDirection:NO];
}

- (void)closeFind:(id)sender {
  BroHideFindBar();
}

- (void)stopFinding {
  CefRefPtr<CefBrowser> browser = [self activeBrowser];
  if (browser) {
    browser->GetHost()->StopFinding(true);
    browser->GetHost()->SetFocus(true);
  }
  NSResponder* responder = previousFirstResponder_;
  if (responder && responder != searchField_ &&
      [responder isKindOfClass:[NSView class]] &&
      [(NSView*)responder window] == self.window) {
    [self.window makeFirstResponder:responder];
  }
  previousFirstResponder_ = nil;
}

- (void)updateIdentifier:(int)identifier
                   count:(int)count
                 ordinal:(int)ordinal {
  if (identifier < lastFindIdentifier_) {
    return;
  }
  [self keepAboveBrowser];
  if (identifier > lastFindIdentifier_) {
    lastFindIdentifier_ = identifier;
    lastActiveOrdinal_ = 0;
  }
  if (count <= 0) {
    countLabel_.stringValue = @"0/0";
    countLabel_.accessibilityLabel = @"No matches";
    return;
  }
  if (ordinal > 0) {
    lastActiveOrdinal_ = ordinal;
  }
  int displayedOrdinal = lastActiveOrdinal_ > 0 ? lastActiveOrdinal_ : 1;
  displayedOrdinal = MIN(displayedOrdinal, count);
  countLabel_.stringValue =
      [NSString stringWithFormat:@"%d/%d", displayedOrdinal, count];
  countLabel_.accessibilityLabel =
      [NSString stringWithFormat:@"Match %d of %d", displayedOrdinal, count];
}

- (void)controlTextDidChange:(NSNotification*)notification {
  [self startNewSearch];
}

@end

static BroFindBar* g_find_bar = nil;
static BOOL g_find_bar_showing = NO;

BOOL BroFindBarVisible(void) {
  return g_find_bar_showing;
}

BOOL BroFindHasQuery(void) {
  return g_find_bar_showing && g_find_bar.hasQuery;
}

static void BroPositionFindBar(NSView* container) {
  const NSSize size = NSMakeSize(330, 36);
  g_find_bar.frame = NSMakeRect(NSWidth(container.bounds) - size.width - 12.0,
                                NSHeight(container.bounds) - size.height - 12.0,
                                size.width, size.height);
  g_find_bar.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
}

void BroShowFindBar(void) {
  NSView* container = BroBrowserContainerView();
  if (!container) {
    return;
  }
  HideCommandPalette();
  BroHideDownloadsPopover();
  if (!g_find_bar) {
    // Construct with its real geometry so shell-derived corners are clamped
    // before the glass backdrop captures the radius.
    g_find_bar = [[BroFindBar alloc]
        initWithFrame:NSMakeRect(0.0, 0.0, 330.0, 36.0)];
    g_find_bar.hidden = YES;
  }
  [g_find_bar removeFromSuperview];
  BroPositionFindBar(container);
  [container addSubview:g_find_bar];
  g_find_bar_showing = YES;
  BroOverlayShow(g_find_bar);
  [g_find_bar prepareForDisplay];
  [g_find_bar.window recalculateKeyViewLoop];
}

void BroHideFindBar(void) {
  if (!g_find_bar_showing) {
    return;
  }
  g_find_bar_showing = NO;
  [g_find_bar stopFinding];
  BroOverlayHide(g_find_bar);
}

void BroFindNext(void) {
  if (!BroFindBarVisible()) {
    BroShowFindBar();
    return;
  }
  [g_find_bar findNext:nil];
}

void BroFindPrevious(void) {
  if (!BroFindBarVisible()) {
    BroShowFindBar();
    return;
  }
  [g_find_bar findPrevious:nil];
}

void BroUpdateFindResult(int browser_id,
                         int identifier,
                         int count,
                         int active_ordinal) {
  BroHandler* handler = BroHandler::GetInstance();
  if (!g_find_bar_showing || !handler ||
      browser_id != handler->GetActiveBrowserId()) {
    return;
  }
  [g_find_bar updateIdentifier:identifier
                         count:count
                       ordinal:active_ordinal];
}

void BroTeardownFindBar(void) {
  g_find_bar_showing = NO;
  [g_find_bar removeFromSuperview];
  g_find_bar = nil;
}
