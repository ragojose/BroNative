// Radix Icons (https://www.radix-ui.com/icons, MIT) rendered natively.
// Icons are embedded as SVG path data and drawn into template NSImages,
// so they can be tinted with contentTintColor like SF Symbols.

#ifndef RADIX_ICONS_H_
#define RADIX_ICONS_H_

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, RadixIcon) {
  RadixIconArrowLeft,
  RadixIconArrowRight,
  RadixIconReload,
  RadixIconPlus,
  RadixIconCross2,
  RadixIconDesktop,
  RadixIconMobile,
  RadixIconGlobe,
};

// Returns a template NSImage of the icon scaled from its native 15x15
// viewBox to pointSize x pointSize.
NSImage* RadixIconImage(RadixIcon icon, CGFloat pointSize);

#endif  // RADIX_ICONS_H_
