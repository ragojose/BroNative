// Native word/glyph text morphing for Bro's AppKit chrome.

#ifndef BRO_TEXT_MORPH_H_
#define BRO_TEXT_MORPH_H_

#import <Cocoa/Cocoa.h>

@interface BroTextMorphView : NSView

- (instancetype)initWithFont:(NSFont*)font color:(NSColor*)color;
- (void)setText:(NSString*)text animated:(BOOL)animated;

@property(nonatomic, copy, readonly) NSString* text;
@property(nonatomic, strong) NSColor* color;
@property(nonatomic, assign, readonly) NSSize desiredSize;

@end

#endif  // BRO_TEXT_MORPH_H_
