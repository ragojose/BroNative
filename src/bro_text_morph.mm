#import "bro_text_morph.h"

#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <utility>
#include <vector>

#import "bro_motion.h"

@interface BroTextToken : NSObject
@property(nonatomic, copy) NSString* value;
@property(nonatomic, assign) NSRange range;
@end

@implementation BroTextToken
@end

// CATextLayer chooses its own baseline from its bounds, which can differ from
// NSTextField by a backing pixel even at the same nominal font size. Draw each
// segment with Core Text at an explicit baseline instead, so resting morph text
// and the editable AppKit field share identical metrics.
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

@interface BroTextMorphSegment : NSObject
@property(nonatomic, copy) NSString* value;
@property(nonatomic, assign) NSRange range;
@property(nonatomic, assign) NSRange previousRange;
@property(nonatomic, strong) BroTextLayer* layer;
@property(nonatomic, assign) CGFloat targetX;
@property(nonatomic, assign) CGFloat width;
@property(nonatomic, assign) BOOL entering;
@end

@implementation BroTextMorphSegment
@end

namespace {

NSArray<BroTextToken*>* WordTokens(NSString* text) {
  NSMutableArray<BroTextToken*>* tokens = [NSMutableArray array];
  NSCharacterSet* whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  NSUInteger index = 0;
  while (index < text.length) {
    while (index < text.length &&
           [whitespace characterIsMember:[text characterAtIndex:index]]) {
      index++;
    }
    NSUInteger start = index;
    while (index < text.length &&
           ![whitespace characterIsMember:[text characterAtIndex:index]]) {
      index++;
    }
    if (index > start) {
      BroTextToken* token = [[BroTextToken alloc] init];
      token.range = NSMakeRange(start, index - start);
      token.value = [text substringWithRange:token.range];
      [tokens addObject:token];
    }
  }
  return tokens;
}

NSArray<BroTextToken*>* GraphemeTokens(NSString* text, NSRange range) {
  NSMutableArray<BroTextToken*>* tokens = [NSMutableArray array];
  [text enumerateSubstringsInRange:range
                           options:NSStringEnumerationByComposedCharacterSequences
                        usingBlock:^(NSString* substring, NSRange substringRange,
                                     NSRange enclosingRange, BOOL* stop) {
    BroTextToken* token = [[BroTextToken alloc] init];
    token.value = substring ?: @"";
    token.range = substringRange;
    [tokens addObject:token];
  }];
  return tokens;
}

std::vector<std::pair<NSUInteger, NSUInteger>> LCSMatches(
    NSArray<BroTextToken*>* oldTokens,
    NSArray<BroTextToken*>* newTokens) {
  const NSUInteger oldCount = oldTokens.count;
  const NSUInteger newCount = newTokens.count;
  std::vector<std::vector<NSUInteger>> dp(
      oldCount + 1, std::vector<NSUInteger>(newCount + 1, 0));
  for (NSInteger i = (NSInteger)oldCount - 1; i >= 0; --i) {
    for (NSInteger j = (NSInteger)newCount - 1; j >= 0; --j) {
      if ([oldTokens[(NSUInteger)i].value
              isEqualToString:newTokens[(NSUInteger)j].value]) {
        dp[(NSUInteger)i][(NSUInteger)j] =
            dp[(NSUInteger)i + 1][(NSUInteger)j + 1] + 1;
      } else {
        dp[(NSUInteger)i][(NSUInteger)j] =
            std::max(dp[(NSUInteger)i + 1][(NSUInteger)j],
                     dp[(NSUInteger)i][(NSUInteger)j + 1]);
      }
    }
  }

  std::vector<std::pair<NSUInteger, NSUInteger>> matches;
  NSUInteger i = 0;
  NSUInteger j = 0;
  while (i < oldCount && j < newCount) {
    if ([oldTokens[i].value isEqualToString:newTokens[j].value]) {
      matches.emplace_back(i++, j++);
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return matches;
}

CGFloat LineHeight(NSFont* font) {
  return ceil(font.ascender - font.descender + font.leading);
}

CATransform3D ScaleTransform(CGFloat scale) {
  return CATransform3DMakeScale(scale, scale, 1.0);
}

}  // namespace

@implementation BroTextMorphView {
  NSFont* font_;
  NSMutableArray<BroTextMorphSegment*>* segments_;
  NSMutableArray<BroTextLayer*>* exitingLayers_;
  NSUInteger generation_;
}

- (instancetype)initWithFont:(NSFont*)font color:(NSColor*)color {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    font_ = font ?: [NSFont systemFontOfSize:12.0];
    _color = color ?: [NSColor labelColor];
    _text = @"";
    segments_ = [NSMutableArray array];
    exitingLayers_ = [NSMutableArray array];
    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;
    _desiredSize = NSMakeSize(0.0, LineHeight(font_));
  }
  return self;
}

- (CGFloat)backingScale {
  return self.window ? self.window.backingScaleFactor
                     : NSScreen.mainScreen.backingScaleFactor ?: 2.0;
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  CGFloat scale = [self backingScale];
  for (BroTextMorphSegment* segment in segments_) {
    segment.layer.contentsScale = scale;
  }
  for (BroTextLayer* layer in exitingLayers_) {
    layer.contentsScale = scale;
  }
}

- (void)setColor:(NSColor*)color {
  _color = color ?: [NSColor labelColor];
  for (BroTextMorphSegment* segment in segments_) {
    segment.layer.textColor = _color;
  }
  for (BroTextLayer* layer in exitingLayers_) {
    layer.textColor = _color;
  }
}

- (CTLineRef)newLineForText:(NSString*)text {
  NSAttributedString* attributed = [[NSAttributedString alloc]
      initWithString:text ?: @""
          attributes:@{
            NSFontAttributeName : font_,
            NSForegroundColorAttributeName : _color,
          }];
  return CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)attributed);
}

- (CGFloat)xForIndex:(NSUInteger)index line:(CTLineRef)line {
  return line ? CTLineGetOffsetForStringIndex(line, (CFIndex)index, nullptr)
              : 0.0;
}

- (CGFloat)segmentCenterY {
  CGFloat lineHeight = LineHeight(font_);
  CGFloat availableHeight = NSHeight(self.bounds);
  return availableHeight > lineHeight ? availableHeight / 2.0
                                      : lineHeight / 2.0;
}

- (BroTextMorphSegment*)newSegmentForToken:(BroTextToken*)token
                                      line:(CTLineRef)line {
  BroTextMorphSegment* segment = [[BroTextMorphSegment alloc] init];
  segment.value = token.value;
  segment.range = token.range;
  segment.previousRange = NSMakeRange(NSNotFound, 0);
  segment.targetX = [self xForIndex:token.range.location line:line];
  CGFloat end = [self xForIndex:NSMaxRange(token.range) line:line];
  segment.width = MAX(1.0, ceil(end - segment.targetX));
  segment.entering = YES;

  BroTextLayer* layer = [BroTextLayer layer];
  layer.contentsScale = [self backingScale];
  layer.textFont = font_;
  layer.textColor = _color;
  layer.text = segment.value;
  // The baseline within the line box is derived from the font descender; the
  // box itself is vertically centered in the view. This matches the AppKit
  // field editor's textContainerInset at every shared font size.
  layer.baselineFromBottom = ceil(-font_.descender);
  layer.bounds = CGRectMake(0.0, 0.0, segment.width, LineHeight(font_));
  layer.position = CGPointMake(segment.targetX + segment.width / 2.0,
                               [self segmentCenterY]);
  segment.layer = layer;
  [self.layer addSublayer:layer];
  return segment;
}

- (NSArray<BroTextMorphSegment*>*)segmentsInsideRange:(NSRange)range {
  NSMutableArray<BroTextMorphSegment*>* result = [NSMutableArray array];
  for (BroTextMorphSegment* segment in segments_) {
    if (segment.range.location >= range.location &&
        NSMaxRange(segment.range) <= NSMaxRange(range)) {
      [result addObject:segment];
    }
  }
  return result;
}

- (NSArray<BroTextMorphSegment*>*)splitSegmentsForWord:(BroTextToken*)word
                                                  line:(CTLineRef)oldLine {
  NSArray<BroTextMorphSegment*>* inside = [self segmentsInsideRange:word.range];
  if (inside.count != 1 ||
      !NSEqualRanges(inside.firstObject.range, word.range)) {
    return inside;
  }
  NSArray<BroTextToken*>* glyphs = GraphemeTokens(_text, word.range);
  if (glyphs.count <= 1) {
    return inside;
  }

  BroTextMorphSegment* wordSegment = inside.firstObject;
  CALayer* presentation = (CALayer*)wordSegment.layer.presentationLayer;
  CGPoint visiblePosition = presentation ? presentation.position
                                         : wordSegment.layer.position;
  CGPoint modelPosition = wordSegment.layer.position;
  CGFloat opacity = presentation ? presentation.opacity
                                 : wordSegment.layer.opacity;
  CATransform3D transform = presentation ? presentation.transform
                                         : wordSegment.layer.transform;
  [wordSegment.layer removeFromSuperlayer];
  [segments_ removeObject:wordSegment];

  NSMutableArray<BroTextMorphSegment*>* split = [NSMutableArray array];
  for (BroTextToken* glyph in glyphs) {
    BroTextMorphSegment* segment = [self newSegmentForToken:glyph line:oldLine];
    segment.entering = NO;
    segment.previousRange = segment.range;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    segment.layer.position = CGPointMake(
        segment.layer.position.x + visiblePosition.x - modelPosition.x,
        segment.layer.position.y + visiblePosition.y - modelPosition.y);
    segment.layer.opacity = opacity;
    segment.layer.transform = transform;
    [CATransaction commit];
    [segments_ addObject:segment];
    [split addObject:segment];
  }
  return split;
}

- (BroTextMorphSegment*)segmentForRange:(NSRange)range
                                  among:(NSArray<BroTextMorphSegment*>*)segments {
  for (BroTextMorphSegment* segment in segments) {
    if (NSEqualRanges(segment.range, range)) {
      return segment;
    }
  }
  return nil;
}

- (void)rebuildImmediately:(NSString*)text line:(CTLineRef)line {
  for (BroTextMorphSegment* segment in segments_) {
    [segment.layer removeFromSuperlayer];
  }
  for (BroTextLayer* layer in exitingLayers_) {
    [layer removeFromSuperlayer];
  }
  [segments_ removeAllObjects];
  [exitingLayers_ removeAllObjects];
  for (BroTextToken* token in WordTokens(text)) {
    BroTextMorphSegment* segment = [self newSegmentForToken:token line:line];
    segment.entering = NO;
    [segments_ addObject:segment];
  }
}

- (void)updateDesiredSizeForLine:(CTLineRef)line {
  CGFloat width = line ? ceil(CTLineGetTypographicBounds(line, nullptr, nullptr,
                                                         nullptr))
                       : 0.0;
  _desiredSize = NSMakeSize(MAX(0.0, width), LineHeight(font_));
}

- (void)setText:(NSString*)text animated:(BOOL)animated {
  text = [text copy] ?: @"";
  if ([_text isEqualToString:text]) {
    return;
  }
  const NSUInteger generation = ++generation_;
  for (CALayer* layer in exitingLayers_) {
    [layer removeFromSuperlayer];
  }
  [exitingLayers_ removeAllObjects];

  CTLineRef newLine = [self newLineForText:text];
  [self updateDesiredSizeForLine:newLine];
  if (!animated || BroMotionReduced() || _text.length == 0) {
    _text = text;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self rebuildImmediately:text line:newLine];
    [CATransaction commit];
    CFRelease(newLine);
    return;
  }

  CTLineRef oldLine = [self newLineForText:_text];
  NSArray<BroTextToken*>* oldWords = WordTokens(_text);
  NSArray<BroTextToken*>* newWords = WordTokens(text);
  std::vector<std::pair<NSUInteger, NSUInteger>> wordMatches =
      LCSMatches(oldWords, newWords);

  NSMutableArray<BroTextMorphSegment*>* targets = [NSMutableArray array];
  NSHashTable<BroTextMorphSegment*>* reused =
      [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];

  auto reuseSegment = ^(BroTextMorphSegment* segment,
                        BroTextToken* oldToken,
                        BroTextToken* newToken) {
    segment.previousRange = segment.range;
    NSUInteger relative = segment.range.location - oldToken.range.location;
    segment.range = NSMakeRange(newToken.range.location + relative,
                                segment.range.length);
    segment.targetX = [self xForIndex:segment.range.location line:newLine];
    CGFloat end = [self xForIndex:NSMaxRange(segment.range) line:newLine];
    segment.width = MAX(1.0, ceil(end - segment.targetX));
    segment.entering = NO;
    [reused addObject:segment];
    [targets addObject:segment];
  };

  auto addNewToken = ^(BroTextToken* token) {
    BroTextMorphSegment* segment = [self newSegmentForToken:token line:newLine];
    [targets addObject:segment];
  };

  NSInteger previousOld = -1;
  NSInteger previousNew = -1;
  wordMatches.emplace_back(oldWords.count, newWords.count);
  for (const auto& match : wordMatches) {
    NSUInteger oldEnd = match.first;
    NSUInteger newEnd = match.second;
    NSUInteger oldStart = (NSUInteger)(previousOld + 1);
    NSUInteger newStart = (NSUInteger)(previousNew + 1);
    NSUInteger pairCount = std::min(oldEnd - oldStart, newEnd - newStart);

    for (NSUInteger offset = 0; offset < pairCount; ++offset) {
      BroTextToken* oldWord = oldWords[oldStart + offset];
      BroTextToken* newWord = newWords[newStart + offset];
      NSArray<BroTextToken*>* oldGlyphs = GraphemeTokens(_text, oldWord.range);
      NSArray<BroTextToken*>* newGlyphs = GraphemeTokens(text, newWord.range);
      auto glyphMatches = LCSMatches(oldGlyphs, newGlyphs);
      CGFloat similarity =
          (CGFloat)glyphMatches.size() /
          (CGFloat)MAX((NSUInteger)1, MAX(oldGlyphs.count, newGlyphs.count));
      if (similarity >= 0.4) {
        NSArray<BroTextMorphSegment*>* oldGlyphSegments =
            [self splitSegmentsForWord:oldWord line:oldLine];
        NSHashTable<BroTextToken*>* matchedNew =
            [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
        for (const auto& glyphMatch : glyphMatches) {
          BroTextToken* oldGlyph = oldGlyphs[glyphMatch.first];
          BroTextToken* newGlyph = newGlyphs[glyphMatch.second];
          BroTextMorphSegment* segment =
              [self segmentForRange:oldGlyph.range among:oldGlyphSegments];
          if (segment) {
            reuseSegment(segment, oldGlyph, newGlyph);
            [matchedNew addObject:newGlyph];
          }
        }
        for (BroTextToken* newGlyph in newGlyphs) {
          if (![matchedNew containsObject:newGlyph]) {
            addNewToken(newGlyph);
          }
        }
      } else {
        addNewToken(newWord);
      }
    }
    for (NSUInteger index = newStart + pairCount; index < newEnd; ++index) {
      addNewToken(newWords[index]);
    }

    if (oldEnd < oldWords.count && newEnd < newWords.count) {
      BroTextToken* oldWord = oldWords[oldEnd];
      BroTextToken* newWord = newWords[newEnd];
      for (BroTextMorphSegment* segment in
           [self segmentsInsideRange:oldWord.range]) {
        reuseSegment(segment, oldWord, newWord);
      }
      previousOld = (NSInteger)oldEnd;
      previousNew = (NSInteger)newEnd;
    }
  }

  [targets sortUsingComparator:^NSComparisonResult(BroTextMorphSegment* lhs,
                                                    BroTextMorphSegment* rhs) {
    if (lhs.range.location < rhs.range.location) return NSOrderedAscending;
    if (lhs.range.location > rhs.range.location) return NSOrderedDescending;
    return NSOrderedSame;
  }];

  NSMutableArray<BroTextMorphSegment*>* exiting = [NSMutableArray array];
  for (BroTextMorphSegment* oldSegment in [segments_ copy]) {
    if (![reused containsObject:oldSegment]) {
      oldSegment.previousRange = oldSegment.range;
      [exiting addObject:oldSegment];
    }
  }

  _text = text;
  segments_ = targets;
  CFTimeInterval duration =
      BroSpringForKeyPath(@"position", BroSpringText).settlingDuration;
  CFTimeInterval enterFade = MIN(duration * 0.5, 0.15);
  CFTimeInterval enterDelay = MIN(duration * 0.25, 0.15);
  CFTimeInterval exitFade = MIN(duration * 0.25, 0.15);

  for (BroTextMorphSegment* segment in segments_) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    segment.layer.bounds = CGRectMake(0.0, 0.0, segment.width,
                                      LineHeight(font_));
    [CATransaction commit];
    CGPoint target = CGPointMake(segment.targetX + segment.width / 2.0,
                                 [self segmentCenterY]);
    if (!segment.entering) {
      BroSpringRetargetPosition(segment.layer, target, BroSpringText,
                                @"bro.text.persist");
      continue;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    segment.layer.position = target;
    segment.layer.opacity = 1.0;
    segment.layer.transform = CATransform3DIdentity;
    [CATransaction commit];
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.0;
    fade.toValue = @1.0;
    fade.duration = enterFade;
    fade.beginTime = CACurrentMediaTime() + enterDelay;
    fade.fillMode = kCAFillModeBackwards;
    [segment.layer addAnimation:fade forKey:@"bro.text.enter.opacity"];
    CASpringAnimation* scale =
        BroSpringForKeyPath(@"transform", BroSpringText);
    scale.fromValue = [NSValue valueWithCATransform3D:ScaleTransform(0.95)];
    scale.toValue =
        [NSValue valueWithCATransform3D:CATransform3DIdentity];
    [segment.layer addAnimation:scale forKey:@"bro.text.enter.transform"];
  }

  for (BroTextMorphSegment* segment in exiting) {
    BroTextMorphSegment* neighbor = nil;
    NSUInteger bestDistance = NSUIntegerMax;
    for (BroTextMorphSegment* candidate in segments_) {
      if (candidate.previousRange.location == NSNotFound) {
        continue;
      }
      NSUInteger lhs = segment.previousRange.location;
      NSUInteger rhs = candidate.previousRange.location;
      NSUInteger distance = lhs > rhs ? lhs - rhs : rhs - lhs;
      if (distance < bestDistance) {
        bestDistance = distance;
        neighbor = candidate;
      }
    }
    CGPoint exitTarget = neighbor ? neighbor.layer.position
                                  : segment.layer.position;
    BroSpringRetargetPosition(segment.layer, exitTarget, BroSpringText,
                              @"bro.text.exit.position");
    CALayer* presentation = (CALayer*)segment.layer.presentationLayer;
    CATransform3D fromTransform = presentation ? presentation.transform
                                               : segment.layer.transform;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    segment.layer.opacity = 0.0;
    segment.layer.transform = ScaleTransform(0.95);
    [CATransaction commit];
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(presentation ? presentation.opacity : 1.0);
    fade.toValue = @0.0;
    fade.duration = exitFade;
    [segment.layer addAnimation:fade forKey:@"bro.text.exit.opacity"];
    CASpringAnimation* scale =
        BroSpringForKeyPath(@"transform", BroSpringText);
    scale.fromValue = [NSValue valueWithCATransform3D:fromTransform];
    scale.toValue = [NSValue valueWithCATransform3D:ScaleTransform(0.95)];
    [segment.layer addAnimation:scale forKey:@"bro.text.exit.transform"];
    [exitingLayers_ addObject:segment.layer];
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(duration * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (self->generation_ != generation) {
      return;
    }
    for (BroTextLayer* layer in [self->exitingLayers_ copy]) {
      [layer removeFromSuperlayer];
    }
    [self->exitingLayers_ removeAllObjects];
  });

  CFRelease(oldLine);
  CFRelease(newLine);
}

@end
