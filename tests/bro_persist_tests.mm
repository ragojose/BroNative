#import <Foundation/Foundation.h>

#import "bro_persist.h"

static void Require(BOOL condition, NSString* message) {
  if (!condition) {
    NSLog(@"appearance persistence test failed: %@", message);
    abort();
  }
}

int main(void) {
  @autoreleasepool {
    NSString* profile = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString
            stringWithFormat:@"BroAppearanceTests-%@",
                             NSUUID.UUID.UUIDString]];
    setenv("BRO_USER_DATA_DIR", profile.fileSystemRepresentation, 1);

    Require(BroLoadAppearancePreference() == BroAppearanceSystem,
            @"missing preference must default to System");

    BroSaveAppearancePreference(BroAppearanceLight);
    Require(BroLoadAppearancePreference() == BroAppearanceLight,
            @"Light must round-trip");
    NSDictionary* light = BroLoadJSONFile(@"preferences.json");
    Require([light[@"appearance"] isEqualToString:@"light"],
            @"Light must use its stable serialized name");

    BroSaveJSONFile(@"preferences.json",
                    @{ @"appearance" : @"light", @"future" : @42 });
    BroSaveAppearancePreference(BroAppearanceDark);
    NSDictionary* dark = BroLoadJSONFile(@"preferences.json");
    Require([dark[@"appearance"] isEqualToString:@"dark"],
            @"Dark must round-trip");
    Require([dark[@"future"] isEqual:@42],
            @"saving appearance must preserve unrelated preferences");

    BroSaveJSONFile(@"preferences.json", @{ @"appearance" : @"unknown" });
    Require(BroLoadAppearancePreference() == BroAppearanceSystem,
            @"unknown values must safely fall back to System");

    [[NSFileManager defaultManager] removeItemAtPath:profile error:nil];
  }
  return 0;
}
