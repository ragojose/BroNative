#import "radix_icons.h"

#include <cctype>
#include <cstdlib>

namespace {

// Path data ("d" attribute) from radix-ui/icons, viewBox 0 0 15 15.
// https://github.com/radix-ui/icons (MIT license).
const char kArrowLeft[] =
    "M6.22457 3.08224C6.41865 2.95407 6.68261 2.97583 6.85348 3.14669C7.02434 "
    "3.31756 7.04609 3.58152 6.91793 3.7756L6.85348 3.85372L3.70699 "
    "7.00021H12.5C12.7761 7.00021 13 7.22406 13 7.50021C13 7.77635 12.7761 "
    "8.00021 12.5 8.00021H3.70699L6.85348 11.1467L6.91793 11.2248C7.04609 "
    "11.4189 7.02434 11.6829 6.85348 11.8537C6.68261 12.0246 6.41865 12.0463 "
    "6.22457 11.9182L6.14645 11.8537L2.14645 7.85372C1.95118 7.65846 1.95118 "
    "7.34195 2.14645 7.14669L6.14645 3.14669L6.22457 3.08224Z";
const char kArrowRight[] =
    "M8.14648 3.14669C8.31735 2.97583 8.58131 2.95407 8.77539 3.08224L8.85352 "
    "3.14669L12.8535 7.14669C13.0488 7.34195 13.0488 7.65846 12.8535 "
    "7.85372L8.85352 11.8537C8.65825 12.049 8.34175 12.049 8.14648 "
    "11.8537C7.95122 11.6585 7.95122 11.342 8.14648 11.1467L11.293 "
    "8.00021H2.5C2.22386 8.00021 2 7.77635 2 7.50021C2 7.22406 2.22386 "
    "7.00021 2.5 7.00021H11.293L8.14648 3.85372L8.08203 3.7756C7.95387 "
    "3.58152 7.97562 3.31756 8.14648 3.14669Z";
const char kReload[] =
    "M7.50037 0.850006C10.6644 0.850189 12.2943 3.06869 12.9994 "
    "4.31094L13.0004 4.31192V2.5004C13.0004 2.22425 13.2242 2.0004 13.5004 "
    "2.0004C13.7763 2.00059 14.0004 2.22438 14.0004 2.5004V5.5004C14.0002 "
    "5.77625 13.7762 6.0002 13.5004 6.0004H10.5004C10.2243 6.0004 10.0006 "
    "5.77637 10.0004 5.5004C10.0004 5.22425 10.2242 5.0004 10.5004 "
    "5.0004H12.2328L12.1215 4.79239C11.4802 3.66597 10.1107 1.85019 7.50037 "
    "1.85001C4.06019 1.85001 1.84998 4.665 1.84998 7.5004C1.85018 10.3357 "
    "4.06034 13.1498 7.50037 13.1498C9.16525 13.1497 10.5296 12.496 11.5013 "
    "11.5072L11.6927 11.3031C12.126 10.8159 12.4715 10.2575 12.7172 "
    "9.66055L12.765 9.57071C12.8948 9.37795 13.1462 9.2963 13.3695 "
    "9.38809C13.6248 9.49314 13.7468 9.78515 13.642 10.0404L13.5111 "
    "10.3373C13.2362 10.9247 12.877 11.4767 12.4398 11.9682L12.2142 "
    "12.2084C11.062 13.3807 9.44396 14.1497 7.50037 14.1498C3.43771 14.1498 "
    "0.850179 10.8149 0.849976 7.5004C0.849976 4.1858 3.43755 0.850006 "
    "7.50037 0.850006Z";
const char kPlus[] =
    "M7.5 2.25C7.77614 2.25 8 2.47386 8 2.75V7H12.25C12.5261 7 12.75 7.22386 "
    "12.75 7.5C12.75 7.77614 12.5261 8 12.25 8H8V12.25C8 12.5261 7.77614 "
    "12.75 7.5 12.75C7.22386 12.75 7 12.5261 7 12.25V8H2.75C2.47386 8 2.25 "
    "7.77614 2.25 7.5C2.25 7.22386 2.47386 7 2.75 7H7V2.75C7 2.47386 7.22386 "
    "2.25 7.5 2.25Z";
const char kCross2[] =
    "M10.9688 3.21871C11.1933 2.99416 11.5567 2.99416 11.7813 3.21871C12.0056 "
    "3.44328 12.0057 3.80673 11.7813 4.03121L8.31251 7.49996L11.7813 "
    "10.9687L11.8555 11.0586C12.0026 11.2817 11.9777 11.5848 11.7813 "
    "11.7812C11.5849 11.9776 11.2818 12.0026 11.0586 11.8554L10.9688 "
    "11.7812L7.50001 8.31246L4.03126 11.7812C3.80677 12.0057 3.44332 12.0056 "
    "3.21876 11.7812C2.99421 11.5567 2.99421 11.1933 3.21876 10.9687L6.68751 "
    "7.49996L3.21876 4.03121L3.14454 3.94137C2.99723 3.71819 3.0223 3.41517 "
    "3.21876 3.21871C3.41522 3.02225 3.71823 2.99719 3.94141 3.14449L4.03126 "
    "3.21871L7.50001 6.68746L10.9688 3.21871Z";
const char kDesktop[] =
    "M13.8779 2.00684C14.5082 2.07092 15 2.60285 15 3.25V10.75C15 11.4404 "
    "14.4404 12 13.75 12H9.92676L10.1699 13.2988L10.1797 13.4238C10.1678 "
    "13.7104 9.93104 13.95 9.62988 13.9502H5.37012C5.02598 13.95 4.76674 "
    "13.6371 4.83008 13.2988L5.07324 12H1.25C0.559644 12 2.14752e-08 11.4404 "
    "0 10.75V3.25C1.34221e-09 2.55964 0.559644 2 1.25 2H13.75L13.8779 "
    "2.00684ZM5.98926 12L5.79297 13.0498H9.20703L9.01074 12H5.98926ZM1.25 "
    "3C1.11193 3 1 3.11193 1 3.25V10.75C1 10.8881 1.11193 11 1.25 "
    "11H13.75C13.8881 11 14 10.8881 14 10.75V3.25C14 3.12931 13.9145 3.02833 "
    "13.8008 3.00488L13.75 3H1.25Z";
const char kMobile[] =
    "M10.5 1C11.3284 1 12 1.67157 12 2.5V12.5C12 13.3284 11.3284 14 10.5 "
    "14H4.5C3.67157 14 3 13.3284 3 12.5V2.5C3 1.67157 3.67157 1 4.5 "
    "1H10.5ZM4.5 2C4.22386 2 4 2.22386 4 2.5V12.5C4 12.7761 4.22386 13 4.5 "
    "13H10.5C10.7761 13 11 12.7761 11 12.5V2.5C11 2.22386 10.7761 2 10.5 "
    "2H4.5ZM9.07031 11.6572C9.2299 11.6898 9.34961 11.8308 9.34961 12C9.34961 "
    "12.1692 9.2299 12.3102 9.07031 12.3428L9 12.3496H6C5.8067 12.3496 "
    "5.65039 12.1933 5.65039 12C5.65039 11.8067 5.8067 11.6504 6 11.6504H9L9."
    "07031 11.6572Z";
const char kGlobe[] =
    "M7.50049 0.900055C11.1453 0.900372 14.1001 3.85576 14.1001 "
    "7.50064C14.0998 11.1453 11.1451 14.0999 7.50049 14.1003C3.8556 14.1003 "
    "0.900219 11.1455 0.899902 7.50064C0.899902 3.85556 3.85541 0.900055 "
    "7.50049 0.900055ZM5.28369 10.7047C5.64404 11.6351 6.17083 12.4782 "
    "6.85889 13.1628C6.93847 13.1717 7.01858 13.1777 7.09912 13.1833V10.8454C"
    "6.48761 10.8314 5.87706 10.7834 5.28369 10.7047ZM9.77295 10.6989C9.16164 "
    "10.7822 8.53116 10.83 7.8999 10.8444V13.1833C7.98109 13.1776 8.06187 "
    "13.1717 8.14209 13.1628C8.85531 12.4766 9.40048 11.6314 9.77295 "
    "10.6989ZM2.35791 9.96158C3.02351 11.3493 4.23482 12.4239 5.71338 "
    "12.9118C5.18397 12.2135 4.77849 11.4213 4.49561 10.5788C3.72434 10.4334 "
    "2.99871 10.2279 2.35791 9.96158ZM12.6411 9.96158C12.0184 10.2204 11.3158 "
    "10.4226 10.5688 10.567C10.2783 11.4105 9.86035 12.2028 9.31592 "
    "12.902C10.781 12.4097 11.98 11.3401 12.6411 9.96158ZM4.7085 7.90005C4."
    "7386 8.60278 4.84803 9.29815 5.03564 9.96255C5.69719 10.0665 6.39354 "
    "10.1284 7.09912 10.1452V7.90005H4.7085ZM7.8999 10.1452C8.6291 10.1279 "
    "9.34852 10.0631 10.0298 9.95279C10.222 9.29117 10.3348 8.59924 10.3657 "
    "7.90005H7.8999V10.1452ZM1.81494 7.90005C1.84166 8.28532 1.90683 8.65978 "
    "2.00635 9.02017C2.63373 9.36462 3.41278 9.63163 4.27686 9.81998C4.12456 "
    "9.19287 4.03416 8.54747 4.0083 7.90005H1.81494ZM11.0669 7.90005C11.0404 "
    "8.54266 10.9472 9.18283 10.7925 9.80533C11.5283 9.64052 12.2013 9.4188 "
    "12.7681 9.13931L12.9917 9.02115C13.0914 8.66036 13.1573 8.28578 13.1841 "
    "7.90005H11.0669ZM4.32666 4.97525C3.47332 5.15752 2.70151 5.41806 2.07373 "
    "5.75162C1.9355 6.18085 1.8484 6.63234 1.81592 7.09927H4.0083C4.03702 "
    "6.38157 4.14246 5.66569 4.32666 4.97525ZM7.09912 4.66177C6.4151 4.67804 "
    "5.73957 4.73639 5.09619 4.83463C4.87181 5.55952 4.74173 6.32486 4.7085 "
    "7.09927H7.09912V4.66177ZM7.8999 7.09927H10.3657C10.3315 6.32843 10.1973 "
    "5.56661 9.96729 4.84439C9.30461 4.7402 8.60679 4.67852 7.8999 "
    "4.66177V7.09927ZM10.7397 4.98892C10.9274 5.67521 11.0375 6.38592 11.0669 "
    "7.09927H13.1841C13.1516 6.63184 13.0628 6.18029 12.9243 5.75064L12.7681 "
    "5.66861C12.1877 5.38241 11.4964 5.15481 10.7397 4.98892ZM5.71338 "
    "2.08658C4.32274 2.54535 3.16814 3.52413 2.48193 4.79361C3.11198 4.54372 "
    "3.81949 4.35141 4.56787 4.21451C4.84612 3.44854 5.22711 2.7277 5.71338 "
    "2.08658ZM9.31592 2.09732C9.81554 2.73886 10.2079 3.45908 10.4937 "
    "4.22525C11.2182 4.36119 11.9031 4.55008 12.5151 4.79263C11.8338 3.53304 "
    "10.6926 2.55992 9.31592 2.09732ZM7.8999 3.96255C8.50199 3.97625 9.10328 "
    "4.02188 9.68799 4.0983C9.31948 3.24599 8.80407 2.47253 8.14307 "
    "1.83658C8.06252 1.82753 7.98143 1.82075 7.8999 1.81509V3.96255ZM7.09912 "
    "1.81509C7.01824 1.82072 6.93782 1.82761 6.85791 1.83658C6.2206 2.47064 "
    "5.72306 3.24178 5.3667 4.09146C5.9339 4.01939 6.51613 3.97585 7.09912 "
    "3.96255V1.81509Z";

const char* PathData(RadixIcon icon) {
  switch (icon) {
    case RadixIconArrowLeft:  return kArrowLeft;
    case RadixIconArrowRight: return kArrowRight;
    case RadixIconReload:     return kReload;
    case RadixIconPlus:       return kPlus;
    case RadixIconCross2:     return kCross2;
    case RadixIconDesktop:    return kDesktop;
    case RadixIconMobile:     return kMobile;
    case RadixIconGlobe:      return kGlobe;
  }
  return kGlobe;
}

bool ReadNumber(const char** pp, CGFloat* out) {
  const char* p = *pp;
  while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\t' || *p == '\r') {
    p++;
  }
  char* end = nullptr;
  double value = strtod(p, &end);
  if (end == p) {
    return false;
  }
  *pp = end;
  *out = (CGFloat)value;
  return true;
}

// Minimal SVG path parser. Radix icon paths only use absolute M/L/H/V/C/Z;
// relative variants and S/s are supported as insurance. Unsupported commands
// abort the remainder of the path rather than crash.
NSBezierPath* PathFromSVG(const char* d) {
  NSBezierPath* path = [NSBezierPath bezierPath];
  path.windingRule = NSWindingRuleEvenOdd;

  const char* p = d;
  char cmd = 0;
  NSPoint cur = NSZeroPoint;
  NSPoint subpathStart = NSZeroPoint;
  NSPoint prevCubicCtrl = NSZeroPoint;
  BOOL hasPrevCubic = NO;

  while (true) {
    while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\t' || *p == '\r') {
      p++;
    }
    if (!*p) {
      break;
    }
    if (isalpha((unsigned char)*p)) {
      cmd = *p++;
      continue;
    }
    if (!cmd) {
      break;
    }

    BOOL rel = (BOOL)islower((unsigned char)cmd);
    switch (toupper((unsigned char)cmd)) {
      case 'M': {
        CGFloat x, y;
        if (!ReadNumber(&p, &x) || !ReadNumber(&p, &y)) return path;
        NSPoint pt = rel ? NSMakePoint(cur.x + x, cur.y + y) : NSMakePoint(x, y);
        [path moveToPoint:pt];
        cur = subpathStart = pt;
        hasPrevCubic = NO;
        cmd = rel ? 'l' : 'L';  // Subsequent implicit pairs are lineTo.
        break;
      }
      case 'L': {
        CGFloat x, y;
        if (!ReadNumber(&p, &x) || !ReadNumber(&p, &y)) return path;
        cur = rel ? NSMakePoint(cur.x + x, cur.y + y) : NSMakePoint(x, y);
        [path lineToPoint:cur];
        hasPrevCubic = NO;
        break;
      }
      case 'H': {
        CGFloat x;
        if (!ReadNumber(&p, &x)) return path;
        cur = NSMakePoint(rel ? cur.x + x : x, cur.y);
        [path lineToPoint:cur];
        hasPrevCubic = NO;
        break;
      }
      case 'V': {
        CGFloat y;
        if (!ReadNumber(&p, &y)) return path;
        cur = NSMakePoint(cur.x, rel ? cur.y + y : y);
        [path lineToPoint:cur];
        hasPrevCubic = NO;
        break;
      }
      case 'C': {
        CGFloat x1, y1, x2, y2, x, y;
        if (!ReadNumber(&p, &x1) || !ReadNumber(&p, &y1) ||
            !ReadNumber(&p, &x2) || !ReadNumber(&p, &y2) ||
            !ReadNumber(&p, &x) || !ReadNumber(&p, &y)) {
          return path;
        }
        NSPoint c1 = rel ? NSMakePoint(cur.x + x1, cur.y + y1) : NSMakePoint(x1, y1);
        NSPoint c2 = rel ? NSMakePoint(cur.x + x2, cur.y + y2) : NSMakePoint(x2, y2);
        NSPoint pt = rel ? NSMakePoint(cur.x + x, cur.y + y) : NSMakePoint(x, y);
        [path curveToPoint:pt controlPoint1:c1 controlPoint2:c2];
        prevCubicCtrl = c2;
        hasPrevCubic = YES;
        cur = pt;
        break;
      }
      case 'S': {
        CGFloat x2, y2, x, y;
        if (!ReadNumber(&p, &x2) || !ReadNumber(&p, &y2) ||
            !ReadNumber(&p, &x) || !ReadNumber(&p, &y)) {
          return path;
        }
        NSPoint c1 = hasPrevCubic
            ? NSMakePoint(2 * cur.x - prevCubicCtrl.x, 2 * cur.y - prevCubicCtrl.y)
            : cur;
        NSPoint c2 = rel ? NSMakePoint(cur.x + x2, cur.y + y2) : NSMakePoint(x2, y2);
        NSPoint pt = rel ? NSMakePoint(cur.x + x, cur.y + y) : NSMakePoint(x, y);
        [path curveToPoint:pt controlPoint1:c1 controlPoint2:c2];
        prevCubicCtrl = c2;
        hasPrevCubic = YES;
        cur = pt;
        break;
      }
      case 'Z': {
        [path closePath];
        cur = subpathStart;
        hasPrevCubic = NO;
        break;
      }
      default:
        NSLog(@"radix_icons: unsupported SVG path command '%c'", cmd);
        return path;
    }
  }
  return path;
}

NSBezierPath* CachedPath(RadixIcon icon) {
  static NSMutableDictionary<NSNumber*, NSBezierPath*>* cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
  });
  NSBezierPath* path = cache[@(icon)];
  if (!path) {
    path = PathFromSVG(PathData(icon));
    cache[@(icon)] = path;
  }
  return path;
}

}  // namespace

NSImage* RadixIconImage(RadixIcon icon, CGFloat pointSize) {
  NSBezierPath* base = CachedPath(icon);
  // flipped:YES matches SVG's y-down coordinate space.
  NSImage* image = [NSImage imageWithSize:NSMakeSize(pointSize, pointSize)
                                  flipped:YES
                           drawingHandler:^BOOL(NSRect dstRect) {
    NSAffineTransform* transform = [NSAffineTransform transform];
    [transform scaleBy:pointSize / 15.0];
    NSBezierPath* scaled = [base copy];
    [scaled transformUsingAffineTransform:transform];
    [[NSColor blackColor] set];
    [scaled fill];
    return YES;
  }];
  [image setTemplate:YES];
  return image;
}
