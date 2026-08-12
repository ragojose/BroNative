// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "bro_persist.h"

static NSString* const kBroPreferencesFilename = @"preferences.json";
static NSString* const kBroAppearancePreferenceKey = @"appearance";

NSString* BroUserDataDirectory(void) {
  static NSString* dir = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (const char* data_dir = getenv("BRO_USER_DATA_DIR")) {
      if (data_dir[0] == '/') {
        dir = [NSString stringWithUTF8String:data_dir];
      }
    }
    if (!dir) {
      NSString* appSupport = NSSearchPathForDirectoriesInDomains(
          NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
      dir = [appSupport stringByAppendingPathComponent:@"Bro"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  });
  return dir;
}

id BroLoadJSONFile(NSString* filename) {
  NSString* path =
      [BroUserDataDirectory() stringByAppendingPathComponent:filename];
  NSData* data = [NSData dataWithContentsOfFile:path];
  if (!data) {
    return nil;
  }
  return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

void BroSaveJSONFile(NSString* filename, id obj) {
  NSData* data =
      [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
  if (!data) {
    return;
  }
  NSString* path =
      [BroUserDataDirectory() stringByAppendingPathComponent:filename];
  [data writeToFile:path options:NSDataWritingAtomic error:nil];
}

BroAppearancePreference BroLoadAppearancePreference(void) {
  id value = BroLoadJSONFile(kBroPreferencesFilename);
  if (![value isKindOfClass:[NSDictionary class]]) {
    return BroAppearanceSystem;
  }
  NSString* appearance = ((NSDictionary*)value)[kBroAppearancePreferenceKey];
  if ([appearance isEqualToString:@"light"]) {
    return BroAppearanceLight;
  }
  if ([appearance isEqualToString:@"dark"]) {
    return BroAppearanceDark;
  }
  return BroAppearanceSystem;
}

void BroSaveAppearancePreference(BroAppearancePreference preference) {
  NSString* value = @"system";
  if (preference == BroAppearanceLight) {
    value = @"light";
  } else if (preference == BroAppearanceDark) {
    value = @"dark";
  }

  id existing = BroLoadJSONFile(kBroPreferencesFilename);
  NSMutableDictionary* preferences =
      [existing isKindOfClass:[NSDictionary class]]
          ? [existing mutableCopy]
          : [NSMutableDictionary dictionary];
  preferences[kBroAppearancePreferenceKey] = value;
  BroSaveJSONFile(kBroPreferencesFilename, preferences);
}
