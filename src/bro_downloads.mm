// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <QuartzCore/QuartzCore.h>

#include "bro_handler.h"
#import "bro_mac_internal.h"
#import "bro_motion.h"
#import "radix_icons.h"

#pragma mark - BroDownloadEntry

// Downloads: the recent list shown in the toolbar popover, newest first.
// Completed entries (capped at kMaxRecentDownloads) persist across launches
// via NSUserDefaults; in-progress entries are session-only.
typedef NS_ENUM(NSInteger, BroDownloadState) {
  BroDownloadStateInProgress,
  BroDownloadStateComplete,
  BroDownloadStateFailed,
};

@interface BroDownloadEntry : NSObject
@property(nonatomic, assign) uint32_t downloadId;  // 0 for restored entries
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* path;
@property(nonatomic, assign) int64_t receivedBytes;
@property(nonatomic, assign) int64_t totalBytes;  // <= 0 when unknown
@property(nonatomic, assign) BroDownloadState state;
@end

@implementation BroDownloadEntry
@end

static const NSUInteger kMaxRecentDownloads = 10;
static NSString* const kBroRecentDownloadsKey = @"BroRecentDownloads";
static NSMutableArray<BroDownloadEntry*>* BroDownloadsList(void);
static void BroSaveRecentDownloads(void);
static void BroRefreshDownloadsPopover(void);
static void BroPulseDownloadsButton(void);

#pragma mark - BroDownloadsPopover

// Floating panel under the toolbar's downloads button: recent downloads
// newest-first (in-flight ones with a progress readout), a Clear action, and
// a "View all downloads" footer that reveals ~/Downloads in Finder. Styled to
// match BroTabHoverCard. Toggled by the button; dismissed by outside clicks
// and Esc via the event monitors installed alongside the show call.
static const CGFloat kDownloadsPopoverWidth = 300.0;
static const CGFloat kDownloadsRowHeight = 44.0;
static const CGFloat kDownloadsHeaderHeight = 28.0;
static const CGFloat kDownloadsFooterHeight = 36.0;
static const CGFloat kDownloadsEmptyHeight = 52.0;

@interface BroDownloadRow : NSView
@property(nonatomic, assign) BOOL interactive;
@property(nonatomic, weak) BroHoverHighlightGroup* highlightGroup;
@property(nonatomic, weak) id target;
@property(nonatomic, assign) SEL action;
@property(nonatomic, assign) NSUInteger downloadIndex;
@end

@implementation BroDownloadRow

- (void)mouseEntered:(NSEvent*)event {
  if (_interactive) {
    [_highlightGroup hoverOnView:self];
  }
}

- (void)mouseExited:(NSEvent*)event {
  if (_interactive) {
    [_highlightGroup hoverOffView:self];
  }
}

- (void)resetCursorRects {
  if (_interactive) {
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
  }
}

- (void)mouseDown:(NSEvent*)event {
}

- (void)mouseUp:(NSEvent*)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (_interactive && NSPointInRect(point, self.bounds)) {
    [NSApp sendAction:_action to:_target from:self];
  }
}

@end

@interface BroDownloadsPopover : NSView
// Rebuilds the rows from the downloads list and resizes self to fit, showing
// at most as many rows as fit in |maxHeight| (newest kept, oldest dropped).
- (void)reloadWithMaxHeight:(CGFloat)maxHeight;
@end

@implementation BroDownloadsPopover {
  NSTextField* headerLabel_;
  BroHoverButton* clearButton_;
  BroHoverButton* viewAllButton_;
  NSView* separator_;
  NSTextField* emptyLabel_;
  NSMutableArray<NSView*>* rowViews_;
  // Entries backing the visible rows; magnifier buttons index into this.
  NSMutableArray<BroDownloadEntry*>* rowEntries_;
  CGFloat lastMaxHeight_;
  BroHoverHighlightGroup* rowHighlightGroup_;
}

static NSAttributedString* BroDownloadsButtonTitle(NSString* text,
                                                   NSFont* font,
                                                   CGFloat whiteAlpha,
                                                   NSTextAlignment alignment) {
  NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
  style.alignment = alignment;
  style.lineBreakMode = NSLineBreakByTruncatingTail;
  return [[NSAttributedString alloc]
      initWithString:text
          attributes:@{
            NSFontAttributeName : font,
            NSForegroundColorAttributeName :
                [NSColor colorWithWhite:1.0 alpha:whiteAlpha],
            NSParagraphStyleAttributeName : style,
          }];
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.cornerRadius = 8.0;
    BroApplyElevation(self, BroElevationPanel);
    rowHighlightGroup_ =
        [[BroHoverHighlightGroup alloc] initWithContainerView:self];

    headerLabel_ = BroHoverCardLabel(BroUIFontBold(10.0), 0.55);
    headerLabel_.attributedStringValue = [[NSAttributedString alloc]
        initWithString:@"RECENT DOWNLOADS"
            attributes:@{
              NSFontAttributeName : BroUIFontBold(10.0),
              NSForegroundColorAttributeName :
                  [NSColor colorWithWhite:1.0 alpha:0.55],
              NSKernAttributeName : @0.5,
            }];
    [self addSubview:headerLabel_];

    clearButton_ = [[BroHoverButton alloc]
        initWithFrame:NSMakeRect(0, 0, 48.0, 20.0)];
    clearButton_.bordered = NO;
    clearButton_.attributedTitle = BroDownloadsButtonTitle(
        @"Clear", BroUIFont(11.0), 0.55, NSTextAlignmentCenter);
    clearButton_.target = self;
    clearButton_.action = @selector(clearDownloads:);
    clearButton_.accessibilityLabel = @"Clear recent downloads";
    [self addSubview:clearButton_];

    emptyLabel_ = BroHoverCardLabel(BroUIFont(12.0), 0.4);
    emptyLabel_.stringValue = @"No recent downloads";
    emptyLabel_.alignment = NSTextAlignmentCenter;
    [self addSubview:emptyLabel_];

    separator_ = [[NSView alloc] initWithFrame:NSZeroRect];
    separator_.wantsLayer = YES;
    separator_.layer.backgroundColor =
        [NSColor colorWithWhite:1.0 alpha:kWindowBorderAlpha].CGColor;
    [self addSubview:separator_];

    viewAllButton_ = [[BroHoverButton alloc] initWithFrame:NSZeroRect];
    viewAllButton_.bordered = NO;
    viewAllButton_.alignment = NSTextAlignmentLeft;
    viewAllButton_.attributedTitle = BroDownloadsButtonTitle(
        @"View all downloads", BroUIFont(12.0), 0.85, NSTextAlignmentLeft);
    viewAllButton_.target = self;
    viewAllButton_.action = @selector(viewAllDownloads:);
    viewAllButton_.accessibilityLabel = @"View all downloads";
    [self addSubview:viewAllButton_];

    rowViews_ = [NSMutableArray array];
    rowEntries_ = [NSMutableArray array];
    lastMaxHeight_ = CGFLOAT_MAX;
  }
  return self;
}

// Swallow clicks so they never fall through to whatever is behind the panel.
- (void)mouseDown:(NSEvent*)event {
}

- (void)reloadWithMaxHeight:(CGFloat)maxHeight {
  lastMaxHeight_ = maxHeight;
  [rowHighlightGroup_ dismissImmediately];
  for (NSView* row in rowViews_) {
    [row removeFromSuperview];
  }
  [rowViews_ removeAllObjects];
  [rowEntries_ removeAllObjects];

  NSArray<BroDownloadEntry*>* entries = BroDownloadsList();
  const CGFloat padTop = 8.0;
  const CGFloat padBottom = 6.0;
  const CGFloat chromeHeight = padTop + kDownloadsHeaderHeight + 1.0 +
                               kDownloadsFooterHeight + padBottom;
  NSUInteger maxRows = 0;
  if (maxHeight > chromeHeight + kDownloadsRowHeight) {
    maxRows = (NSUInteger)((maxHeight - chromeHeight) / kDownloadsRowHeight);
  }
  NSUInteger rowCount = MIN(entries.count, maxRows);
  for (NSUInteger i = 0; i < rowCount; i++) {
    [rowEntries_ addObject:entries[i]];
  }

  const CGFloat width = kDownloadsPopoverWidth;
  CGFloat listHeight = rowCount > 0 ? rowCount * kDownloadsRowHeight
                                    : kDownloadsEmptyHeight;
  CGFloat height = chromeHeight + listHeight;

  // Bottom-up (unflipped coords): footer, separator, rows oldest-first, then
  // the header at the top.
  viewAllButton_.frame = NSMakeRect(4.0, padBottom, width - 8.0,
                                    kDownloadsFooterHeight);
  separator_.frame = NSMakeRect(0, padBottom + kDownloadsFooterHeight,
                                width, 1.0);

  CGFloat listBottom = padBottom + kDownloadsFooterHeight + 1.0;
  emptyLabel_.hidden = rowCount > 0;
  if (rowCount == 0) {
    CGFloat labelHeight =
        ceil([emptyLabel_.cell cellSizeForBounds:NSMakeRect(0, 0, CGFLOAT_MAX,
                                                            CGFLOAT_MAX)]
                 .height);
    emptyLabel_.frame = NSMakeRect(
        12.0, listBottom + (kDownloadsEmptyHeight - labelHeight) / 2.0,
        width - 24.0, labelHeight);
  }

  for (NSUInteger i = 0; i < rowCount; i++) {
    BroDownloadEntry* entry = rowEntries_[i];
    // Row i is the i-th newest; stack from the top of the list area down.
    CGFloat rowY = listBottom + (rowCount - 1 - i) * kDownloadsRowHeight;
    NSView* row = [self makeRowForEntry:entry index:i];
    row.frame = NSMakeRect(0, rowY, width, kDownloadsRowHeight);
    [self addSubview:row];
    [rowViews_ addObject:row];
  }

  CGFloat headerY = listBottom + listHeight;
  headerLabel_.frame = NSMakeRect(12.0, headerY + 7.0, width - 80.0, 14.0);
  clearButton_.frame = NSMakeRect(width - 12.0 - 48.0, headerY + 4.0,
                                  48.0, 20.0);
  BOOL anySettled = NO;
  for (BroDownloadEntry* entry in entries) {
    if (entry.state != BroDownloadStateInProgress) {
      anySettled = YES;
      break;
    }
  }
  clearButton_.hidden = !anySettled;

  [self setFrameSize:NSMakeSize(width, height)];
}

- (NSView*)makeRowForEntry:(BroDownloadEntry*)entry index:(NSUInteger)index {
  BroDownloadRow* row = [[BroDownloadRow alloc] initWithFrame:NSZeroRect];

  BOOL fileExists = entry.path.length > 0 &&
      [[NSFileManager defaultManager] fileExistsAtPath:entry.path];
  row.interactive = entry.state == BroDownloadStateComplete && fileExists;
  row.highlightGroup = rowHighlightGroup_;
  row.target = self;
  row.action = @selector(openEntry:);
  row.downloadIndex = index;
  if (row.interactive) {
    row.accessibilityElement = YES;
    row.accessibilityRole = NSAccessibilityButtonRole;
    row.accessibilityLabel =
        [NSString stringWithFormat:@"Open %@", entry.name ?: @"download"];
    NSTrackingArea* trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:row
            userInfo:nil];
    [row addTrackingArea:trackingArea];
  }

  NSImageView* icon = [[NSImageView alloc]
      initWithFrame:NSMakeRect(12.0, 8.0, 28.0, 28.0)];
  if (entry.state == BroDownloadStateComplete && fileExists) {
    icon.image = [[NSWorkspace sharedWorkspace] iconForFile:entry.path];
  } else {
    icon.image = RadixIconImage(RadixIconDownload, 15.0);
    icon.contentTintColor = [NSColor colorWithWhite:1.0 alpha:0.55];
  }
  [row addSubview:icon];

  BOOL showsMagnifier = entry.state == BroDownloadStateComplete && fileExists;
  const CGFloat textX = 48.0;
  CGFloat textRight = showsMagnifier ? kDownloadsPopoverWidth - 12.0 - 24.0 - 6.0
                                     : kDownloadsPopoverWidth - 12.0;

  NSTextField* name = BroHoverCardLabel(BroUIFontBold(12.0), 1.0);
  name.stringValue = entry.name ?: @"";
  name.frame = NSMakeRect(textX, 22.0, textRight - textX, 15.0);
  [row addSubview:name];

  NSTextField* subtitle = BroHoverCardLabel(BroUIFont(11.0), 0.55);
  subtitle.stringValue = [self subtitleForEntry:entry fileExists:fileExists];
  subtitle.frame = NSMakeRect(textX, 7.0, textRight - textX, 13.0);
  [row addSubview:subtitle];

  if (entry.state == BroDownloadStateInProgress) {
    CGFloat barWidth = textRight - textX;
    NSView* track = [[NSView alloc]
        initWithFrame:NSMakeRect(textX, 4.0, barWidth, 2.0)];
    track.wantsLayer = YES;
    track.layer.cornerRadius = 1.0;
    track.layer.backgroundColor =
        [NSColor colorWithWhite:1.0 alpha:0.15].CGColor;
    [row addSubview:track];
    if (entry.totalBytes > 0) {
      double fraction = MIN(
          1.0, (double)entry.receivedBytes / (double)entry.totalBytes);
      NSView* fill = [[NSView alloc]
          initWithFrame:NSMakeRect(textX, 4.0, barWidth * fraction, 2.0)];
      fill.wantsLayer = YES;
      fill.layer.cornerRadius = 1.0;
      fill.layer.backgroundColor =
          [NSColor colorWithWhite:1.0 alpha:0.85].CGColor;
      [row addSubview:fill];
    }
  }

  if (showsMagnifier) {
    BroHoverButton* reveal = [[BroHoverButton alloc]
        initWithFrame:NSMakeRect(kDownloadsPopoverWidth - 12.0 - 24.0, 10.0,
                                 24.0, 24.0)];
    reveal.bordered = NO;
    reveal.title = @"";
    reveal.imagePosition = NSImageOnly;
    reveal.image = RadixIconImage(RadixIconMagnifyingGlass, 15.0);
    reveal.contentTintColor = [NSColor colorWithWhite:1.0 alpha:0.85];
    reveal.toolTip = @"Show in Finder";
    reveal.accessibilityLabel =
        [NSString stringWithFormat:@"Show %@ in Finder", entry.name];
    reveal.tag = (NSInteger)index;
    reveal.target = self;
    reveal.action = @selector(revealEntry:);
    [row addSubview:reveal];
  }

  return row;
}

- (void)openEntry:(BroDownloadRow*)sender {
  NSUInteger index = sender.downloadIndex;
  if (index >= rowEntries_.count) {
    return;
  }
  BroDownloadEntry* entry = rowEntries_[index];
  if (entry.state == BroDownloadStateComplete && entry.path.length > 0 &&
      [[NSFileManager defaultManager] fileExistsAtPath:entry.path]) {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL fileURLWithPath:entry.path]];
    BroHideDownloadsPopover();
  }
}

- (NSString*)subtitleForEntry:(BroDownloadEntry*)entry
                   fileExists:(BOOL)fileExists {
  switch (entry.state) {
    case BroDownloadStateInProgress: {
      NSString* received = [NSByteCountFormatter
          stringFromByteCount:entry.receivedBytes
                   countStyle:NSByteCountFormatterCountStyleFile];
      if (entry.totalBytes > 0) {
        NSString* total = [NSByteCountFormatter
            stringFromByteCount:entry.totalBytes
                     countStyle:NSByteCountFormatterCountStyleFile];
        return [NSString stringWithFormat:@"%@ of %@", received, total];
      }
      return received;
    }
    case BroDownloadStateFailed:
      return @"Failed";
    case BroDownloadStateComplete: {
      if (!fileExists) {
        return @"Deleted";
      }
      NSURL* url = [NSURL fileURLWithPath:entry.path];
      NSString* kind = nil;
      [url getResourceValue:&kind
                     forKey:NSURLLocalizedTypeDescriptionKey
                      error:nil];
      if (kind.length > 0) {
        return kind;
      }
      NSString* ext = entry.name.pathExtension;
      return ext.length > 0
                 ? [NSString stringWithFormat:@"%@ file", ext.lowercaseString]
                 : @"File";
    }
  }
  return @"";
}

- (void)revealEntry:(NSButton*)sender {
  NSUInteger index = (NSUInteger)sender.tag;
  if (index >= rowEntries_.count) {
    return;
  }
  BroDownloadEntry* entry = rowEntries_[index];
  if (entry.path.length > 0) {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[
      [NSURL fileURLWithPath:entry.path]
    ]];
  }
}

- (void)clearDownloads:(id)sender {
  // Drop settled entries only; active downloads stay until they finish.
  NSMutableArray<BroDownloadEntry*>* list = BroDownloadsList();
  for (NSUInteger i = 0; i < list.count;) {
    if (list[i].state == BroDownloadStateInProgress) {
      i++;
    } else {
      [list removeObjectAtIndex:i];
    }
  }
  BroSaveRecentDownloads();
  [self reloadWithMaxHeight:lastMaxHeight_];
}

- (void)viewAllDownloads:(id)sender {
  NSString* dir = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory,
                                                      NSUserDomainMask, YES)
                      .firstObject;
  if (dir.length > 0) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir
                                                      isDirectory:YES]];
  }
  BroHideDownloadsPopover();
}

@end

#pragma mark - Downloads popover wiring

static BroDownloadsPopover* g_downloads_popover = nil;
// Installed while the popover is visible; both are removed on hide (a leaked
// monitor would keep re-hiding on every later click).
static id g_downloads_click_monitor = nil;
static id g_downloads_key_monitor = nil;

static BOOL BroDownloadsPopoverVisible(void) {
  return g_downloads_popover && !g_downloads_popover.hidden &&
         g_downloads_popover.superview != nil;
}

static void BroPositionDownloadsPopover(void) {
  NSView* container = BroBrowserContainerView();
  if (!container || !g_downloads_popover) {
    return;
  }
  NSRect bounds = container.bounds;
  CGFloat w = NSWidth(g_downloads_popover.frame);
  CGFloat h = NSHeight(g_downloads_popover.frame);
  // Right edge under the downloads button, clamped inside the container.
  CGFloat x = NSMaxX(bounds) - w - 8.0;
  NSView* anchor = g_toolbar.downloadsButton;
  if (anchor) {
    NSRect a = [container convertRect:anchor.bounds fromView:anchor];
    x = MAX(8.0, MIN(NSMaxX(a) - w, NSMaxX(bounds) - w - 8.0));
  }
  g_downloads_popover.frame =
      NSMakeRect(x, NSMaxY(bounds) - h - 6.0, w, h);
}

static void BroRemoveDownloadsMonitors(void) {
  if (g_downloads_click_monitor) {
    [NSEvent removeMonitor:g_downloads_click_monitor];
    g_downloads_click_monitor = nil;
  }
  if (g_downloads_key_monitor) {
    [NSEvent removeMonitor:g_downloads_key_monitor];
    g_downloads_key_monitor = nil;
  }
}

// BroHideDownloadsPopover is declared extern in bro_mac_internal.h.
void BroHideDownloadsPopover(void) {
  BroRemoveDownloadsMonitors();
  BroOverlayHide(g_downloads_popover);
}

static void BroShowDownloadsPopover(void) {
  NSView* container = BroBrowserContainerView();
  if (!container) {
    return;
  }
  if (!g_downloads_popover) {
    g_downloads_popover =
        [[BroDownloadsPopover alloc] initWithFrame:NSZeroRect];
    g_downloads_popover.hidden = YES;
    // Tracks the top-right corner across window resizes.
    g_downloads_popover.autoresizingMask =
        NSViewMinXMargin | NSViewMinYMargin;
  }
  // (Re-)add last so the panel composites above the native CEF browser view.
  [g_downloads_popover removeFromSuperview];
  [container addSubview:g_downloads_popover];
  [g_downloads_popover reloadWithMaxHeight:NSHeight(container.bounds) - 12.0];
  BroPositionDownloadsPopover();
  BroOverlayShow(g_downloads_popover);

  if (!g_downloads_click_monitor) {
    g_downloads_click_monitor = BroInstallOutsideDismissMonitor(
        g_downloads_popover,
        nil,
        ^NSView*{ return g_toolbar.downloadsButton; },
        ^{ BroHideDownloadsPopover(); });
  }
  if (!g_downloads_key_monitor) {
    g_downloads_key_monitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent*(NSEvent* event) {
      if (event.keyCode == 53) {  // Esc
        BroHideDownloadsPopover();
        return nil;
      }
      return event;
    }];
  }
}

// BroToggleDownloadsPopover is declared extern in bro_mac_internal.h.
void BroToggleDownloadsPopover(void) {
  if (BroDownloadsPopoverVisible()) {
    BroHideDownloadsPopover();
  } else {
    BroShowDownloadsPopover();
  }
}

static void BroRefreshDownloadsPopover(void) {
  if (!BroDownloadsPopoverVisible()) {
    return;
  }
  NSView* container = BroBrowserContainerView();
  CGFloat maxHeight =
      container ? NSHeight(container.bounds) - 12.0 : CGFLOAT_MAX;
  [g_downloads_popover reloadWithMaxHeight:maxHeight];
  BroPositionDownloadsPopover();
}

// Nudge when a download starts or finishes; enough without stealing the
// pointer like an auto-shown panel would. The toolbar owns the animation:
// the button hides at rest, so the pulse is a brief reveal (or an opacity
// dip when already revealed by hover).
static void BroPulseDownloadsButton(void) {
  [g_toolbar pulseDownloadsButton];
}

#pragma mark - Downloads model

static NSMutableArray<BroDownloadEntry*>* BroDownloadsList(void) {
  static NSMutableArray<BroDownloadEntry*>* list = nil;
  if (!list) {
    list = [NSMutableArray array];
    NSArray* saved = [[NSUserDefaults standardUserDefaults]
        arrayForKey:kBroRecentDownloadsKey];
    for (NSDictionary* dict in saved) {
      if (![dict isKindOfClass:[NSDictionary class]]) {
        continue;
      }
      NSString* name = dict[@"name"];
      NSString* path = dict[@"path"];
      if (![name isKindOfClass:[NSString class]] || name.length == 0 ||
          ![path isKindOfClass:[NSString class]]) {
        continue;
      }
      BroDownloadEntry* entry = [[BroDownloadEntry alloc] init];
      entry.name = name;
      entry.path = path;
      entry.state = BroDownloadStateComplete;
      [list addObject:entry];
      if (list.count >= kMaxRecentDownloads) {
        break;
      }
    }
  }
  return list;
}

// Persists completed entries only: in-progress rows would be stale after a
// relaunch and failed ones aren't worth keeping.
static void BroSaveRecentDownloads(void) {
  NSMutableArray<NSDictionary*>* saved = [NSMutableArray array];
  for (BroDownloadEntry* entry in BroDownloadsList()) {
    if (entry.state != BroDownloadStateComplete) {
      continue;
    }
    [saved addObject:@{@"name" : entry.name ?: @"", @"path" : entry.path ?: @""}];
    if (saved.count >= kMaxRecentDownloads) {
      break;
    }
  }
  [[NSUserDefaults standardUserDefaults] setObject:saved
                                            forKey:kBroRecentDownloadsKey];
}

static BroDownloadEntry* BroDownloadEntryForId(uint32_t download_id) {
  if (download_id == 0) {
    return nil;
  }
  for (BroDownloadEntry* entry in BroDownloadsList()) {
    if (entry.downloadId == download_id) {
      return entry;
    }
  }
  return nil;
}

// Caps settled (complete/failed) entries at kMaxRecentDownloads, oldest out;
// in-progress entries are never dropped.
static void BroTrimDownloadsList(void) {
  NSMutableArray<BroDownloadEntry*>* list = BroDownloadsList();
  NSUInteger settled = 0;
  for (NSUInteger i = 0; i < list.count;) {
    if (list[i].state == BroDownloadStateInProgress) {
      i++;
      continue;
    }
    if (++settled > kMaxRecentDownloads) {
      [list removeObjectAtIndex:i];
    } else {
      i++;
    }
  }
}

std::string ResolveDownloadTargetPath(const std::string& suggested_name) {
  // Called on the main thread from OnBeforeDownload, so the list is safe to
  // read. lastPathComponent defends against separators in a server-supplied
  // filename.
  NSString* suggested =
      [NSString stringWithUTF8String:suggested_name.c_str()] ?: @"download";
  NSString* name = suggested.lastPathComponent;
  if (name.length == 0 || [name isEqualToString:@"/"]) {
    name = @"download";
  }
  NSString* dir = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory,
                                                      NSUserDomainMask, YES)
                      .firstObject
      ?: NSTemporaryDirectory();
  NSString* base = name.stringByDeletingPathExtension;
  NSString* ext = name.pathExtension;
  NSFileManager* fm = [NSFileManager defaultManager];
  for (NSUInteger n = 0;; n++) {
    NSString* candidateName;
    if (n == 0) {
      candidateName = name;
    } else if (ext.length > 0) {
      candidateName =
          [NSString stringWithFormat:@"%@ (%lu).%@", base, (unsigned long)n, ext];
    } else {
      candidateName = [NSString stringWithFormat:@"%@ (%lu)", base, (unsigned long)n];
    }
    NSString* candidate = [dir stringByAppendingPathComponent:candidateName];
    BOOL taken = [fm fileExistsAtPath:candidate];
    if (!taken) {
      // Two simultaneous downloads of the same name: the first file may not
      // exist on disk yet, but its target is already claimed.
      for (BroDownloadEntry* entry in BroDownloadsList()) {
        if (entry.state == BroDownloadStateInProgress &&
            [entry.path isEqualToString:candidate]) {
          taken = YES;
          break;
        }
      }
    }
    if (!taken) {
      return std::string(candidate.UTF8String);
    }
  }
}

void OnDownloadStarted(uint32_t download_id,
                       const std::string& file_name,
                       const std::string& full_path) {
  NSString* name = [NSString stringWithUTF8String:file_name.c_str()] ?: @"download";
  NSString* path = [NSString stringWithUTF8String:full_path.c_str()] ?: @"";
  BroRunOnMain(^{
    BroDownloadEntry* entry = BroDownloadEntryForId(download_id);
    if (!entry) {
      entry = [[BroDownloadEntry alloc] init];
      entry.downloadId = download_id;
      [BroDownloadsList() insertObject:entry atIndex:0];
    }
    entry.name = name;
    entry.path = path;
    entry.receivedBytes = 0;
    entry.totalBytes = -1;
    entry.state = BroDownloadStateInProgress;
    BroTrimDownloadsList();
    BroRefreshDownloadsPopover();
    BroPulseDownloadsButton();
  });
}

void OnDownloadProgress(uint32_t download_id,
                        int64_t received_bytes,
                        int64_t total_bytes) {
  BroRunOnMain(^{
    BroDownloadEntry* entry = BroDownloadEntryForId(download_id);
    if (!entry || entry.state != BroDownloadStateInProgress) {
      return;
    }
    entry.receivedBytes = received_bytes;
    entry.totalBytes = total_bytes;
    // OnDownloadUpdated can fire many times per second; the model stays
    // current above but the popover repaints at most ~10 Hz.
    static CFTimeInterval lastRender = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastRender < 0.1) {
      return;
    }
    lastRender = now;
    BroRefreshDownloadsPopover();
  });
}

void OnDownloadFinished(uint32_t download_id,
                        const std::string& full_path,
                        bool success) {
  NSString* path = [NSString stringWithUTF8String:full_path.c_str()] ?: @"";
  BroRunOnMain(^{
    BroDownloadEntry* entry = BroDownloadEntryForId(download_id);
    if (!entry) {
      return;
    }
    entry.state = success ? BroDownloadStateComplete : BroDownloadStateFailed;
    if (path.length > 0) {
      // Canonical final path: Chromium downloads via .crdownload and renames.
      entry.path = path;
      entry.name = path.lastPathComponent;
    }
    BroTrimDownloadsList();
    BroSaveRecentDownloads();
    BroRefreshDownloadsPopover();
    BroPulseDownloadsButton();
  });
}
