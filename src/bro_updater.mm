#import "bro_updater.h"

#import <Sparkle/Sparkle.h>

namespace {

// Placeholder shipped in Info.plist until the release owner generates a real
// key pair. Sparkle would otherwise fail every check and show the user an
// error dialog, so builds carrying the placeholder skip the updater entirely.
NSString* const kPlaceholderPublicKey = @"REPLACE_WITH_SPARKLE_PUBLIC_KEY";

SPUStandardUpdaterController* g_updater = nil;

// True when Info.plist carries a feed URL and a real EdDSA public key.
bool UpdaterIsConfigured() {
  NSDictionary* info = NSBundle.mainBundle.infoDictionary;
  NSString* feed = info[@"SUFeedURL"];
  NSString* key = info[@"SUPublicEDKey"];
  if (feed.length == 0 || key.length == 0) {
    return false;
  }
  return ![key isEqualToString:kPlaceholderPublicKey];
}

}  // namespace

void BroStartUpdater(void) {
  if (g_updater) {
    return;
  }
  if (!UpdaterIsConfigured()) {
    NSLog(@"Bro: Sparkle not configured (placeholder SUPublicEDKey); "
          @"automatic updates are off for this build.");
    return;
  }
  // startingUpdater:YES kicks off the scheduled background check. Sparkle owns
  // its own UI, so there is no delegate to supply here.
  g_updater = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES
                                                           updaterDelegate:nil
                                                        userDriverDelegate:nil];
}

id BroUpdaterMenuTarget(void) {
  return g_updater;
}

SEL BroUpdaterMenuAction(void) {
  return @selector(checkForUpdates:);
}
