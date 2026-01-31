// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <Cocoa/Cocoa.h>

#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "bro_app.h"
#include "bro_handler.h"

// Forward declarations
@class BroWindow;
@class BroToolbar;
@class BroTabBar;
@class BroTabView;

// Constants
static const CGFloat kToolbarHeight = 52.0;
static const CGFloat kTabBarHeight = 36.0;
static const CGFloat kButtonSize = 28.0;
static const CGFloat kButtonSpacing = 4.0;
static const CGFloat kTabMinWidth = 120.0;
static const CGFloat kTabMaxWidth = 240.0;

// Global references
static BroWindow* g_main_window = nil;
static BroToolbar* g_toolbar = nil;
static BroTabBar* g_tab_bar = nil;

// Map browser IDs to their container views
static NSMutableDictionary<NSNumber*, NSView*>* g_browser_views = nil;

// Pending container view for browser creation (set before CreateBrowser, consumed by OnTabCreated)
static NSView* g_pending_browser_container = nil;

// Forward declaration of tab creation functions (implemented after BroWindow)
static void CreateNewBrowserTab(void);
static void CreateNewBrowserTabWithURL(const std::string& url);

#pragma mark - BroToolbar

@interface BroToolbar : NSView <NSTextFieldDelegate>
@property (nonatomic, strong) NSButton* backButton;
@property (nonatomic, strong) NSButton* forwardButton;
@property (nonatomic, strong) NSButton* refreshButton;
@property (nonatomic, strong) NSTextField* addressField;
@property (nonatomic, strong) NSProgressIndicator* loadingIndicator;
@end

@implementation BroToolbar

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    // Performance: Enable layer-backing for GPU compositing
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

    // Create navigation buttons
    CGFloat x = 80.0;  // Leave space for window controls
    CGFloat y = (frame.size.height - kButtonSize) / 2.0;

    // Back button
    _backButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                        image:@"chevron.left"
                                       action:@selector(goBack:)];
    [self addSubview:_backButton];
    x += kButtonSize + kButtonSpacing;

    // Forward button
    _forwardButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                           image:@"chevron.right"
                                          action:@selector(goForward:)];
    [self addSubview:_forwardButton];
    x += kButtonSize + kButtonSpacing;

    // Refresh button
    _refreshButton = [self createButtonWithFrame:NSMakeRect(x, y, kButtonSize, kButtonSize)
                                           image:@"arrow.clockwise"
                                          action:@selector(refresh:)];
    [self addSubview:_refreshButton];
    x += kButtonSize + kButtonSpacing + 8.0;

    // Address field
    CGFloat addressWidth = frame.size.width - x - 16.0;
    _addressField = [[NSTextField alloc] initWithFrame:NSMakeRect(x, y + 2, addressWidth, kButtonSize - 4)];
    _addressField.autoresizingMask = NSViewWidthSizable;
    _addressField.font = [NSFont systemFontOfSize:13.0];
    _addressField.bezeled = YES;
    _addressField.bezelStyle = NSTextFieldRoundedBezel;
    _addressField.drawsBackground = YES;
    _addressField.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.1];
    _addressField.textColor = [NSColor labelColor];
    _addressField.placeholderString = @"Enter URL or search";
    _addressField.delegate = self;
    _addressField.cell.scrollable = YES;
    _addressField.cell.usesSingleLineMode = YES;
    [self addSubview:_addressField];

    // Loading indicator (hidden by default)
    _loadingIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(x + addressWidth - 24, y + 6, 16, 16)];
    _loadingIndicator.autoresizingMask = NSViewMinXMargin;
    _loadingIndicator.style = NSProgressIndicatorStyleSpinning;
    _loadingIndicator.controlSize = NSControlSizeSmall;
    _loadingIndicator.hidden = YES;
    [self addSubview:_loadingIndicator];

    // Initial button states
    _backButton.enabled = NO;
    _forwardButton.enabled = NO;
  }
  return self;
}

- (NSButton*)createButtonWithFrame:(NSRect)frame image:(NSString*)imageName action:(SEL)action {
  NSButton* button = [[NSButton alloc] initWithFrame:frame];
  button.bezelStyle = NSBezelStyleTexturedRounded;
  button.bordered = NO;

  // Use SF Symbols
  if (@available(macOS 11.0, *)) {
    NSImage* image = [NSImage imageWithSystemSymbolName:imageName accessibilityDescription:nil];
    NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
    button.image = [image imageWithSymbolConfiguration:config];
  }

  button.target = self;
  button.action = action;

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
  if (urlString.length == 0) return;

  // Add https:// if no scheme
  if (![urlString containsString:@"://"]) {
    // Check if it looks like a URL
    if ([urlString containsString:@"."] && ![urlString containsString:@" "]) {
      urlString = [@"https://" stringByAppendingString:urlString];
    } else {
      // Treat as search query
      NSString* encoded = [urlString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
      urlString = [NSString stringWithFormat:@"https://www.google.com/search?q=%@", encoded];
    }
  }

  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      browser->GetMainFrame()->LoadURL([urlString UTF8String]);
    }
  }
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification*)notification {
  NSTextField* textField = notification.object;
  if (textField == _addressField) {
    NSNumber* reason = notification.userInfo[@"NSTextMovement"];
    if (reason && reason.integerValue == NSReturnTextMovement) {
      [self navigateToURL:_addressField.stringValue];
    }
  }
}

#pragma mark - State Updates

- (void)updateNavigationState:(BOOL)canGoBack canGoForward:(BOOL)canGoForward {
  _backButton.enabled = canGoBack;
  _forwardButton.enabled = canGoForward;
}

- (void)updateURL:(NSString*)url {
  _addressField.stringValue = url ?: @"";
}

- (void)setLoading:(BOOL)loading {
  if (loading) {
    _loadingIndicator.hidden = NO;
    [_loadingIndicator startAnimation:nil];
  } else {
    [_loadingIndicator stopAnimation:nil];
    _loadingIndicator.hidden = YES;
  }
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
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL selectAction;
@property (nonatomic, assign) SEL closeAction;
- (void)setFaviconURL:(NSString*)urlString;
- (void)setLoading:(BOOL)loading;
@end

@implementation BroTabView

- (instancetype)initWithFrame:(NSRect)frame browserId:(int)browserId {
  self = [super initWithFrame:frame];
  if (self) {
    _browserId = browserId;
    _isActive = NO;
    _isLoading = NO;

    self.wantsLayer = YES;
    self.layer.cornerRadius = 6.0;

    // Favicon view
    _faviconView = [[NSImageView alloc] initWithFrame:NSMakeRect(6, 8, 16, 16)];
    _faviconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    // Default globe icon
    if (@available(macOS 11.0, *)) {
      _faviconView.image = [NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:nil];
      _faviconView.contentTintColor = [NSColor secondaryLabelColor];
    }
    [self addSubview:_faviconView];

    // Loading spinner (same position as favicon, hidden by default)
    _loadingSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(6, 8, 16, 16)];
    _loadingSpinner.style = NSProgressIndicatorStyleSpinning;
    _loadingSpinner.controlSize = NSControlSizeSmall;
    _loadingSpinner.hidden = YES;
    [self addSubview:_loadingSpinner];

    // Title label (after favicon)
    _titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(26, 8, frame.size.width - 50, 20)];
    _titleLabel.stringValue = @"New Tab";
    _titleLabel.font = [NSFont systemFontOfSize:12.0];
    _titleLabel.textColor = [NSColor secondaryLabelColor];
    _titleLabel.bordered = NO;
    _titleLabel.editable = NO;
    _titleLabel.drawsBackground = NO;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.cell.truncatesLastVisibleLine = YES;
    _titleLabel.autoresizingMask = NSViewWidthSizable;
    [self addSubview:_titleLabel];

    // Close button
    _closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 24, 8, 16, 16)];
    _closeButton.bezelStyle = NSBezelStyleTexturedRounded;
    _closeButton.bordered = NO;
    if (@available(macOS 11.0, *)) {
      NSImage* closeImage = [NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close"];
      NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightMedium];
      _closeButton.image = [closeImage imageWithSymbolConfiguration:config];
    }
    _closeButton.target = self;
    _closeButton.action = @selector(handleClose:);
    _closeButton.autoresizingMask = NSViewMinXMargin;
    _closeButton.hidden = YES;  // Show on hover
    [self addSubview:_closeButton];

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

- (void)updateAppearance {
  if (_isActive) {
    self.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.15].CGColor;
    _titleLabel.textColor = [NSColor labelColor];
  } else {
    self.layer.backgroundColor = [NSColor clearColor].CGColor;
    _titleLabel.textColor = [NSColor secondaryLabelColor];
  }
}

- (void)setIsActive:(BOOL)isActive {
  _isActive = isActive;
  [self updateAppearance];
}

- (void)mouseDown:(NSEvent*)event {
  if (_target && _selectAction) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [_target performSelector:_selectAction withObject:self];
#pragma clang diagnostic pop
  }
}

- (void)mouseEntered:(NSEvent*)event {
  _closeButton.hidden = NO;
  if (!_isActive) {
    self.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.08].CGColor;
  }
}

- (void)mouseExited:(NSEvent*)event {
  _closeButton.hidden = YES;
  if (!_isActive) {
    self.layer.backgroundColor = [NSColor clearColor].CGColor;
  }
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

@interface BroTabBar : NSView
@property (nonatomic, strong) NSMutableArray<BroTabView*>* tabs;
@property (nonatomic, strong) NSButton* addTabButton;
@property (nonatomic, assign) int activeTabId;
- (void)addTabWithBrowserId:(int)browserId title:(NSString*)title;
- (void)removeTabWithBrowserId:(int)browserId;
- (void)setActiveTab:(int)browserId;
- (void)updateTabTitle:(int)browserId title:(NSString*)title;
- (void)updateTabFavicon:(int)browserId faviconURL:(NSString*)url;
- (void)updateTabLoading:(int)browserId loading:(BOOL)loading;
@end

@implementation BroTabBar

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _tabs = [NSMutableArray array];
    _activeTabId = -1;
    self.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    // Performance: Enable layer-backing for GPU compositing
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

    // New tab button
    _addTabButton = [[NSButton alloc] initWithFrame:NSMakeRect(8, 4, 28, 28)];
    _addTabButton.bezelStyle = NSBezelStyleTexturedRounded;
    _addTabButton.bordered = NO;
    if (@available(macOS 11.0, *)) {
      NSImage* plusImage = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"New Tab"];
      NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
      _addTabButton.image = [plusImage imageWithSymbolConfiguration:config];
    }
    _addTabButton.target = self;
    _addTabButton.action = @selector(createNewTab:);
    [self addSubview:_addTabButton];
  }
  return self;
}

- (void)createNewTab:(id)sender {
  CreateNewBrowserTab();
}

- (void)addTabWithBrowserId:(int)browserId title:(NSString*)title {
  CGFloat x = 40.0;  // After new tab button
  for (BroTabView* tab in _tabs) {
    x += tab.frame.size.width + 4.0;
  }

  CGFloat tabWidth = MIN(MAX(kTabMinWidth, (self.frame.size.width - 48) / (_tabs.count + 1)), kTabMaxWidth);

  BroTabView* tab = [[BroTabView alloc] initWithFrame:NSMakeRect(x, 2, tabWidth, kTabBarHeight - 4)
                                            browserId:browserId];
  tab.titleLabel.stringValue = title ?: @"New Tab";
  tab.target = self;
  tab.selectAction = @selector(tabSelected:);
  tab.closeAction = @selector(tabClosed:);
  [_tabs addObject:tab];
  [self addSubview:tab];

  [self layoutTabs];
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
    [tabToRemove removeFromSuperview];
    [_tabs removeObject:tabToRemove];
    [self layoutTabs];
  }
}

- (void)setActiveTab:(int)browserId {
  _activeTabId = browserId;
  for (BroTabView* tab in _tabs) {
    tab.isActive = (tab.browserId == browserId);
  }
}

- (void)updateTabTitle:(int)browserId title:(NSString*)title {
  for (BroTabView* tab in _tabs) {
    if (tab.browserId == browserId) {
      tab.titleLabel.stringValue = title ?: @"New Tab";
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
  if (_tabs.count == 0) return;

  CGFloat availableWidth = self.frame.size.width - 48.0;  // Space after new tab button
  CGFloat tabWidth = MIN(MAX(kTabMinWidth, availableWidth / _tabs.count - 4.0), kTabMaxWidth);

  CGFloat x = 40.0;
  for (BroTabView* tab in _tabs) {
    tab.frame = NSMakeRect(x, 2, tabWidth, kTabBarHeight - 4);
    x += tabWidth + 4.0;
  }
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  [self layoutTabs];
}

- (void)tabSelected:(BroTabView*)tab {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    handler->SetActiveBrowser(tab.browserId);
  }
}

- (void)tabClosed:(BroTabView*)tab {
  // Don't close the last tab
  if (_tabs.count <= 1) {
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
    // Transparent titlebar for vibrancy effect
    self.titlebarAppearsTransparent = YES;
    self.titleVisibility = NSWindowTitleHidden;
    self.backgroundColor = [NSColor clearColor];

    // Create visual effect view for vibrancy
    NSVisualEffectView* visualEffect = [[NSVisualEffectView alloc] initWithFrame:frame];
    visualEffect.material = NSVisualEffectMaterialUnderWindowBackground;
    visualEffect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    visualEffect.state = NSVisualEffectStateFollowsWindowActiveState;
    visualEffect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.contentView = visualEffect;

    // Create tab bar (at top, under title bar area)
    // Leave 80px on left for traffic lights (close/minimize/zoom)
    CGFloat trafficLightSpace = 80.0;
    CGFloat tabBarY = frame.size.height - kTabBarHeight;
    _tabBar = [[BroTabBar alloc] initWithFrame:NSMakeRect(trafficLightSpace, tabBarY, frame.size.width - trafficLightSpace, kTabBarHeight)];
    [visualEffect addSubview:_tabBar];
    g_tab_bar = _tabBar;

    // Create toolbar (below tab bar)
    CGFloat toolbarY = tabBarY - kToolbarHeight;
    _navToolbar = [[BroToolbar alloc] initWithFrame:NSMakeRect(0, toolbarY, frame.size.width, kToolbarHeight)];
    [visualEffect addSubview:_navToolbar];
    g_toolbar = _navToolbar;

    // Create container for browser views (below toolbar)
    CGFloat browserHeight = toolbarY;
    _browserContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, browserHeight)];
    _browserContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [visualEffect addSubview:_browserContainer];

    // Initialize browser views dictionary
    g_browser_views = [NSMutableDictionary dictionary];

    // Center the window
    [self center];

    // Set minimum size
    self.minSize = NSMakeSize(400, 300);
  }
  return self;
}

@end

#pragma mark - CreateNewBrowserTab

static void CreateNewBrowserTabWithURL(const std::string& url) {
  if (!g_main_window || !g_main_window.browserContainer) {
    return;
  }

  BroHandler* handler = BroHandler::GetInstance();
  if (!handler) {
    return;
  }

  // Create a container view for the new browser
  NSView* browserContainer = [[NSView alloc] initWithFrame:g_main_window.browserContainer.bounds];
  browserContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  browserContainer.hidden = YES;  // Will be shown when tab is activated
  [g_main_window.browserContainer addSubview:browserContainer];

  // Store pending container for OnTabCreated to pick up
  g_pending_browser_container = browserContainer;

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
  // Create the main menu
  [self setupMainMenu];

  // Create the main window with vibrancy
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

  // Zoom controls
  [viewMenu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"+"];
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
    fprintf(stderr, "[BRO] createBrowserInWindow: g_main_window or browserContainer is nil\n");
    return;
  }

  NSRect containerBounds = g_main_window.browserContainer.bounds;
  NSRect containerFrame = g_main_window.browserContainer.frame;
  fprintf(stderr, "[BRO] createBrowserInWindow called\n");
  fprintf(stderr, "[BRO] g_main_window.browserContainer.bounds = %.0f x %.0f\n",
          containerBounds.size.width, containerBounds.size.height);
  fprintf(stderr, "[BRO] g_main_window.browserContainer.frame = %.0f, %.0f, %.0f x %.0f\n",
          containerFrame.origin.x, containerFrame.origin.y,
          containerFrame.size.width, containerFrame.size.height);

  // Create the handler (shared across all browsers)
  CefRefPtr<BroHandler> handler(new BroHandler(true));

  // Create a container view for the first browser
  NSView* browserContainer = [[NSView alloc] initWithFrame:g_main_window.browserContainer.bounds];
  browserContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [g_main_window.browserContainer addSubview:browserContainer];

  fprintf(stderr, "[BRO] browserContainer bounds: %.0f x %.0f\n",
          browserContainer.bounds.size.width, browserContainer.bounds.size.height);

  // Store pending container for OnTabCreated to pick up
  g_pending_browser_container = browserContainer;

  // Browser settings
  CefBrowserSettings browser_settings;

  // Window info - embed in the container view
  CefWindowInfo window_info;
  NSRect bounds = browserContainer.bounds;

  fprintf(stderr, "[BRO] Creating browser with bounds: %.0f x %.0f\n",
          bounds.size.width, bounds.size.height);

  window_info.SetAsChild(
      CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(browserContainer),
      CefRect(0, 0, bounds.size.width, bounds.size.height));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  // Create the browser
  std::string url = "https://www.google.com";
  bool result = CefBrowserHost::CreateBrowser(window_info, handler, url, browser_settings,
                                nullptr, nullptr);
  fprintf(stderr, "[BRO] CefBrowserHost::CreateBrowser returned: %d\n", result);

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

- (void)newWindow:(id)sender {
  // Create a new window with a new browser
  BroWindow* newWindow = [[BroWindow alloc] init];
  newWindow.delegate = self;
  newWindow.title = @"Bro";
  [newWindow makeKeyAndOrderFront:nil];

  // Create a browser in the new window
  BroHandler* handler = BroHandler::GetInstance();
  if (handler && newWindow.browserContainer) {
    NSView* browserContainer = [[NSView alloc] initWithFrame:newWindow.browserContainer.bounds];
    browserContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [newWindow.browserContainer addSubview:browserContainer];

    g_pending_browser_container = browserContainer;

    CefBrowserSettings browser_settings;
    CefWindowInfo window_info;
    NSRect bounds = browserContainer.bounds;
    window_info.SetAsChild(
        CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(browserContainer),
        CefRect(0, 0, bounds.size.width, bounds.size.height));
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

    std::string url = "https://www.google.com";
    CefBrowserHost::CreateBrowser(window_info, handler, url, browser_settings,
                                  nullptr, nullptr);
  }
}

- (void)newTab:(id)sender {
  if (g_tab_bar) {
    [g_tab_bar createNewTab:sender];
  }
}

- (void)closeTab:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    int activeId = handler->GetActiveBrowserId();
    // Only close if there's more than one tab
    if (g_tab_bar && g_tab_bar.tabs.count > 1) {
      handler->CloseBrowser(activeId);
    }
  }
}

- (void)focusAddressBar:(id)sender {
  if (g_toolbar && g_toolbar.addressField) {
    [g_main_window makeFirstResponder:g_toolbar.addressField];
    [g_toolbar.addressField selectText:nil];
  }
}

- (void)zoomIn:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      double currentZoom = browser->GetHost()->GetZoomLevel();
      browser->GetHost()->SetZoomLevel(currentZoom + 0.5);
    }
  }
}

- (void)zoomOut:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      double currentZoom = browser->GetHost()->GetZoomLevel();
      browser->GetHost()->SetZoomLevel(currentZoom - 0.5);
    }
  }
}

- (void)zoomReset:(id)sender {
  BroHandler* handler = BroHandler::GetInstance();
  if (handler) {
    CefRefPtr<CefBrowser> browser = handler->GetBrowser();
    if (browser) {
      browser->GetHost()->SetZoomLevel(0.0);
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
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_toolbar) {
      [g_toolbar updateURL:[NSString stringWithUTF8String:url.c_str()]];
    }
  });
}

void SetLoading(bool loading) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_toolbar) {
      [g_toolbar setLoading:loading];
    }
  });
}

void OnTabCreated(int browser_id, const std::string& url) {
  fprintf(stderr, "[BRO] OnTabCreated called with browser_id=%d, url=%s\n", browser_id, url.c_str());
  dispatch_async(dispatch_get_main_queue(), ^{
    // Store the pending container view for this browser ID
    if (g_pending_browser_container) {
      g_browser_views[@(browser_id)] = g_pending_browser_container;
      fprintf(stderr, "[BRO] Stored pending container for browser_id=%d\n", browser_id);
      NSRect frame = g_pending_browser_container.frame;
      fprintf(stderr, "[BRO] Container frame: %.0f, %.0f, %.0f x %.0f\n",
              frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
      fprintf(stderr, "[BRO] Container hidden=%d\n", g_pending_browser_container.hidden);
      fprintf(stderr, "[BRO] Container subviews count=%lu\n", (unsigned long)g_pending_browser_container.subviews.count);
      g_pending_browser_container = nil;
    } else {
      fprintf(stderr, "[BRO] WARNING: g_pending_browser_container is nil!\n");
    }

    // Add tab to tab bar
    if (g_tab_bar) {
      [g_tab_bar addTabWithBrowserId:browser_id title:@"New Tab"];
      [g_tab_bar setActiveTab:browser_id];
      fprintf(stderr, "[BRO] Added tab for browser_id=%d\n", browser_id);
    }

    // Show this browser's container, hide others
    for (NSNumber* key in g_browser_views) {
      NSView* view = g_browser_views[key];
      view.hidden = (key.intValue != browser_id);
      fprintf(stderr, "[BRO] Browser view %d hidden=%d\n", key.intValue, view.hidden);
    }
    fprintf(stderr, "[BRO] Total browser views: %lu\n", (unsigned long)g_browser_views.count);
  });
}

void OnTabTitleChanged(int browser_id, const std::string& title) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_tab_bar) {
      NSString* titleStr = [NSString stringWithUTF8String:title.c_str()];
      [g_tab_bar updateTabTitle:browser_id title:titleStr];
    }
  });
}

void OnTabFaviconChanged(int browser_id, const std::string& favicon_url) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_tab_bar) {
      NSString* urlStr = [NSString stringWithUTF8String:favicon_url.c_str()];
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
  dispatch_async(dispatch_get_main_queue(), ^{
    CreateNewBrowserTabWithURL(url);
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

    // Enable remote debugging (useful for troubleshooting)
    settings.remote_debugging_port = 9222;

    // Set a cache path for persistent data
    NSString* cachePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"BroCache"];
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
