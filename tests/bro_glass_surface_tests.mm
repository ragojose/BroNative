#import <AppKit/AppKit.h>

#import "bro_motion.h"

// bro_geometry.h's production root is resolved from NSThemeFrame in
// bro_mac.mm. The isolated surface test does not link the browser/window
// implementation, so provide the same deterministic design-scale root.
CGFloat BroShellCornerRadius(void) {
  return 12.0;
}

static void Require(BOOL condition, NSString* message) {
  if (!condition) {
    NSLog(@"glass surface test failed: %@", message);
    abort();
  }
}

static NSView* FindSubviewOfClass(NSView* parent, Class cls) {
  for (NSView* child in parent.subviews) {
    if ([child isKindOfClass:cls]) {
      return child;
    }
  }
  return nil;
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];

    if (@available(macOS 26.0, *)) {
      unsetenv("BRO_FORCE_LEGACY_GLASS");
      NSView* shell = [[NSView alloc]
          initWithFrame:NSMakeRect(0, 0, 640, 480)];
      NSView* shellContent = BroInstallShellSurface(shell, 12.0);
      NSGlassEffectView* shellGlass = (NSGlassEffectView*)
          FindSubviewOfClass(shell, [NSGlassEffectView class]);
      Require(shellGlass != nil, @"shell must use NSGlassEffectView");
      Require(shellGlass.contentView == shellContent,
              @"shell controls must live in native contentView");
      Require(shellGlass.style == NSGlassEffectViewStyleRegular,
              @"shell must use Regular glass");
      Require(shellGlass.tintColor == nil,
              @"shell glass must remain neutral");
      Require(fabs(shellGlass.cornerRadius - 12.0) < 0.01,
              @"shell radius must be handed to AppKit");

      NSView* panel = [[NSView alloc]
          initWithFrame:NSMakeRect(0, 0, 320, 180)];
      BroApplyElevation(panel, BroElevationPanel);
      NSView* panelContent = BroInstallGlassSurface(panel, 10.0);
      NSGlassEffectView* panelGlass = (NSGlassEffectView*)
          FindSubviewOfClass(panel, [NSGlassEffectView class]);
      Require(panelGlass != nil, @"overlay must use NSGlassEffectView");
      Require(panelGlass.contentView == panelContent,
              @"overlay controls must live in native contentView");
      Require(fabs(panelGlass.cornerRadius - 10.0) < 0.01,
              @"overlay radius must be handed to AppKit");

      NSView* tabs = [[NSView alloc]
          initWithFrame:NSMakeRect(0, 0, 600, 52)];
      NSView* tabDocument = BroGlassContainerForContentView(tabs, 6.0);
      Require([tabDocument isKindOfClass:[NSGlassEffectContainerView class]],
              @"tab content must use NSGlassEffectContainerView");
      NSGlassEffectContainerView* tabContainer =
          (NSGlassEffectContainerView*)tabDocument;
      Require(tabContainer.contentView == tabs,
              @"tab content must be owned by the native container");
      Require(fabs(tabContainer.spacing - 6.0) < 0.01,
              @"tab merge proximity must be handed to AppKit");

      setenv("BRO_FORCE_LEGACY_GLASS", "1", 1);
      NSView* fallback = [[NSView alloc]
          initWithFrame:NSMakeRect(0, 0, 320, 180)];
      NSView* fallbackContent = BroInstallGlassSurface(fallback, 10.0);
      Require(FindSubviewOfClass(fallback, [NSGlassEffectView class]) == nil,
              @"forced fallback must not instantiate native glass");
      Require(FindSubviewOfClass(fallback, [NSVisualEffectView class]) != nil,
              @"forced fallback must retain NSVisualEffectView");
      Require(fallbackContent.superview == fallback,
              @"fallback content host must remain usable");
      NSView* fallbackTabs = [[NSView alloc]
          initWithFrame:NSMakeRect(0, 0, 600, 52)];
      Require(BroGlassContainerForContentView(fallbackTabs, 6.0) ==
                  fallbackTabs,
              @"legacy tab content must bypass the unavailable container");
    }
  }
  return 0;
}
