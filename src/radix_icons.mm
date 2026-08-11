#import "radix_icons.h"

namespace {

// Bundle resource name for each icon's PDF, under Resources/Icons. Matches
// the upstream radix-ui/icons file names the path data was originally
// exported from.
NSString* IconResourceName(RadixIcon icon) {
  switch (icon) {
    case RadixIconArrowLeft:  return @"arrow-left";
    case RadixIconArrowRight: return @"arrow-right";
    case RadixIconArrowUp:    return @"arrow-up";
    case RadixIconArrowDown:  return @"arrow-down";
    case RadixIconReload:     return @"reload";
    case RadixIconPlus:       return @"plus";
    case RadixIconCross2:     return @"cross-2";
    case RadixIconDesktop:    return @"desktop";
    case RadixIconMobile:     return @"mobile";
    case RadixIconGlobe:      return @"globe";
    case RadixIconDrawingPin:       return @"drawing-pin";
    case RadixIconDrawingPinFilled: return @"drawing-pin-filled";
    case RadixIconViewVertical:     return @"view-vertical";
    case RadixIconDownload:         return @"download";
    case RadixIconMagnifyingGlass:  return @"magnifying-glass";
    case RadixIconChevronDown:      return @"chevron-down";
  }
  return @"globe";
}

// Loads and caches the PDF-backed NSImage for an icon, at its native 15x15
// size. NSImage's PDF representation is resolution-independent, so this is
// redrawn crisply at any requested pointSize below.
NSImage* CachedIconImage(RadixIcon icon) {
  static NSMutableDictionary<NSNumber*, NSImage*>* cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
  });
  NSImage* image = cache[@(icon)];
  if (!image) {
    NSString* path = [[NSBundle mainBundle] pathForResource:IconResourceName(icon)
                                                       ofType:@"pdf"
                                                  inDirectory:@"Icons"];
    image = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (!image) {
      NSLog(@"radix_icons: missing PDF asset for icon %ld", (long)icon);
      image = [[NSImage alloc] initWithSize:NSMakeSize(15, 15)];
    }
    cache[@(icon)] = image;
  }
  return image;
}

}  // namespace

NSImage* RadixIconImage(RadixIcon icon, CGFloat pointSize) {
  NSImage* base = CachedIconImage(icon);
  NSImage* image = [NSImage imageWithSize:NSMakeSize(pointSize, pointSize)
                                  flipped:NO
                           drawingHandler:^BOOL(NSRect dstRect) {
    [base drawInRect:dstRect
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0];
    return YES;
  }];
  [image setTemplate:YES];
  return image;
}
