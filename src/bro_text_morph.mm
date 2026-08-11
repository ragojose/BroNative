#import "bro_text_morph.h"

#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>

#include <cmath>

#import "bro_motion.h"

namespace {

static NSString* const kShimmerAnimationKey = @"bro.text.loading-shimmer";
static NSString* const kTextColorAnimationKey = @"bro.text.color";
static const CFTimeInterval kShimmerSweepDuration = 1.25;
static const CFTimeInterval kTextColorTransitionDuration = 0.18;

CGFloat LineHeight(NSFont* font) {
  return ceil(font.ascender - font.descender + font.leading);
}

}  // namespace

// CATextLayer chooses its own baseline from its bounds, which can differ from
// NSTextField by a backing pixel at the same nominal font size. Core Text at
// an explicit baseline keeps compact and editable text precisely aligned.
@interface BroTextLayer : CALayer
@property(nonatomic, copy) NSString* text;
@property(nonatomic, strong) NSFont* textFont;
@property(nonatomic, strong) NSColor* textColor;
@property(nonatomic, assign) CGFloat baselineFromBottom;
@end

@implementation BroTextLayer

- (instancetype)init {
  self = [super init];
  if (self) {
    self.needsDisplayOnBoundsChange = YES;
  }
  return self;
}

- (void)setText:(NSString*)text {
  _text = [text copy] ?: @"";
  [self setNeedsDisplay];
}

- (void)setTextFont:(NSFont*)font {
  _textFont = font;
  [self setNeedsDisplay];
}

- (void)setTextColor:(NSColor*)color {
  _textColor = color;
  [self setNeedsDisplay];
}

- (void)setBaselineFromBottom:(CGFloat)baseline {
  _baselineFromBottom = baseline;
  [self setNeedsDisplay];
}

- (void)drawInContext:(CGContextRef)context {
  if (_text.length == 0 || !_textFont || !_textColor) {
    return;
  }
  NSAttributedString* attributed = [[NSAttributedString alloc]
      initWithString:_text
          attributes:@{
            NSFontAttributeName : _textFont,
            NSForegroundColorAttributeName : _textColor,
          }];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)attributed);
  CGContextSetTextPosition(context, 0.0, _baselineFromBottom);
  CTLineDraw(line, context);
  CFRelease(line);
}

@end


@implementation BroShimmerTextView {
  NSFont* font_;
  BroTextLayer* baseTextLayer_;
  BroTextLayer* shimmerMaskLayer_;
  CAGradientLayer* shimmerLayer_;
}

- (instancetype)initWithFont:(NSFont*)font color:(NSColor*)color {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    font_ = font ?: [NSFont systemFontOfSize:12.0];
    _color = color ?: [NSColor labelColor];
    _text = @"";
    _desiredSize = NSMakeSize(0.0, LineHeight(font_));

    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;

    baseTextLayer_ = [BroTextLayer layer];
    baseTextLayer_.textFont = font_;
    baseTextLayer_.textColor = _color;
    baseTextLayer_.baselineFromBottom = ceil(-font_.descender);
    [self.layer addSublayer:baseTextLayer_];

    // The shimmer is a gradient clipped by a second Core Text layer. Both
    // layers receive the same complete string in one disabled transaction,
    // so the overlay can brighten the glyphs but can never show stale text.
    shimmerMaskLayer_ = [BroTextLayer layer];
    shimmerMaskLayer_.textFont = font_;
    shimmerMaskLayer_.textColor = [NSColor whiteColor];
    shimmerMaskLayer_.baselineFromBottom = ceil(-font_.descender);

    NSColor* clear = [NSColor colorWithWhite:1.0 alpha:0.0];
    NSColor* highlight = [NSColor colorWithWhite:1.0 alpha:0.24];
    shimmerLayer_ = [CAGradientLayer layer];
    shimmerLayer_.colors = @[
      (__bridge id)clear.CGColor,
      (__bridge id)clear.CGColor,
      (__bridge id)highlight.CGColor,
      (__bridge id)clear.CGColor,
      (__bridge id)clear.CGColor,
    ];
    shimmerLayer_.locations = @[ @0.0, @0.42, @0.5, @0.58, @1.0 ];
    shimmerLayer_.startPoint = CGPointMake(1.0, 0.5);
    shimmerLayer_.endPoint = CGPointMake(2.0, 0.5);
    shimmerLayer_.mask = shimmerMaskLayer_;
    shimmerLayer_.hidden = YES;
    [self.layer addSublayer:shimmerLayer_];

    [self updateBackingScale];
    [[NSWorkspace sharedWorkspace].notificationCenter
        addObserver:self
           selector:@selector(accessibilityDisplayOptionsChanged:)
               name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
             object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
}

- (CGFloat)backingScale {
  return self.window ? self.window.backingScaleFactor
                     : NSScreen.mainScreen.backingScaleFactor ?: 2.0;
}

- (void)updateBackingScale {
  CGFloat scale = [self backingScale];
  baseTextLayer_.contentsScale = scale;
  shimmerMaskLayer_.contentsScale = scale;
  shimmerLayer_.contentsScale = scale;
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [self updateBackingScale];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self updateBackingScale];
  [self refreshShimmer];
}

- (void)setHidden:(BOOL)hidden {
  if (self.hidden == hidden) {
    return;
  }
  [super setHidden:hidden];
  [self refreshShimmer];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self layoutTextLayers];
  [self refreshShimmer];
}

- (void)layout {
  [super layout];
  [self layoutTextLayers];
}

- (void)layoutTextLayers {
  CGFloat lineHeight = LineHeight(font_);
  CGFloat y = MAX(0.0, floor((NSHeight(self.bounds) - lineHeight) / 2.0));
  CGRect textFrame = CGRectMake(0.0, y, NSWidth(self.bounds), lineHeight);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  baseTextLayer_.frame = textFrame;
  shimmerLayer_.frame = self.bounds;
  shimmerMaskLayer_.frame = textFrame;
  [CATransaction commit];
}

- (void)setColor:(NSColor*)color {
  color = color ?: [NSColor labelColor];
  if ([_color isEqual:color]) {
    return;
  }
  if (self.window != nil && !self.hidden && !BroMotionReduced()) {
    CATransition* fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = kTextColorTransitionDuration;
    fade.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [baseTextLayer_ addAnimation:fade forKey:kTextColorAnimationKey];
  }
  _color = color;
  baseTextLayer_.textColor = _color;
}

- (void)setText:(NSString*)text {
  text = [text copy] ?: @"";
  if ([_text isEqualToString:text]) {
    return;
  }

  _text = text;
  NSAttributedString* attributed = [[NSAttributedString alloc]
      initWithString:_text
          attributes:@{NSFontAttributeName : font_}];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)attributed);
  CGFloat width = ceil(CTLineGetTypographicBounds(line, nullptr, nullptr,
                                                   nullptr));
  CFRelease(line);
  _desiredSize = NSMakeSize(MAX(0.0, width), LineHeight(font_));

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  baseTextLayer_.text = _text;
  shimmerMaskLayer_.text = _text;
  [CATransaction commit];
  [self refreshShimmer];
}

- (void)setLoading:(BOOL)loading {
  if (_loading == loading) {
    return;
  }
  _loading = loading;
  [self refreshShimmer];
}

- (void)accessibilityDisplayOptionsChanged:(NSNotification*)notification {
  [self refreshShimmer];
}

- (BOOL)shouldShimmer {
  return _loading && self.window != nil && !self.hidden && _text.length > 0 &&
         NSWidth(self.bounds) > 0.0 && !BroMotionReduced();
}

- (void)refreshShimmer {
  if (![self shouldShimmer]) {
    [shimmerLayer_ removeAnimationForKey:kShimmerAnimationKey];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shimmerLayer_.hidden = YES;
    [CATransaction commit];
    return;
  }
  if ([shimmerLayer_ animationForKey:kShimmerAnimationKey]) {
    return;
  }

  // Move a narrow highlight through the text for 0.9s, then leave it fully
  // off the right edge for 0.35s before the next pass. The base text never
  // moves or fades, so stopping the animation is immediate and artifact-free.
  CAKeyframeAnimation* startSweep =
      [CAKeyframeAnimation animationWithKeyPath:@"startPoint"];
  startSweep.values = @[
    [NSValue valueWithPoint:NSMakePoint(-1.0, 0.5)],
    [NSValue valueWithPoint:NSMakePoint(1.0, 0.5)],
    [NSValue valueWithPoint:NSMakePoint(1.0, 0.5)],
  ];
  startSweep.keyTimes = @[ @0.0, @0.72, @1.0 ];
  startSweep.calculationMode = kCAAnimationLinear;

  CAKeyframeAnimation* endSweep =
      [CAKeyframeAnimation animationWithKeyPath:@"endPoint"];
  endSweep.values = @[
    [NSValue valueWithPoint:NSMakePoint(0.0, 0.5)],
    [NSValue valueWithPoint:NSMakePoint(2.0, 0.5)],
    [NSValue valueWithPoint:NSMakePoint(2.0, 0.5)],
  ];
  endSweep.keyTimes = startSweep.keyTimes;
  endSweep.calculationMode = kCAAnimationLinear;

  CAAnimationGroup* sweep = [CAAnimationGroup animation];
  sweep.animations = @[ startSweep, endSweep ];
  sweep.duration = kShimmerSweepDuration;
  sweep.repeatCount = HUGE_VALF;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  shimmerLayer_.hidden = NO;
  shimmerLayer_.startPoint = CGPointMake(1.0, 0.5);
  shimmerLayer_.endPoint = CGPointMake(2.0, 0.5);
  [CATransaction commit];
  [shimmerLayer_ addAnimation:sweep forKey:kShimmerAnimationKey];
}

@end
