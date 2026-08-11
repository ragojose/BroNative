// Atomic text rendering with a loading shimmer for Bro's AppKit chrome.

#ifndef BRO_TEXT_MORPH_H_
#define BRO_TEXT_MORPH_H_

#import <Cocoa/Cocoa.h>

// The filename is retained to avoid churn in the build manifest, but the old
// word/glyph morphing implementation is intentionally gone. This view always
// owns one complete string and may overlay only a same-string shimmer mask.
@interface BroShimmerTextView : NSView

- (instancetype)initWithFont:(NSFont*)font color:(NSColor*)color;
- (void)setText:(NSString*)text;

@property(nonatomic, copy, readonly) NSString* text;
@property(nonatomic, strong) NSColor* color;
@property(nonatomic, assign, getter=isLoading) BOOL loading;
@property(nonatomic, assign, readonly) NSSize desiredSize;

@end

#endif  // BRO_TEXT_MORPH_H_
