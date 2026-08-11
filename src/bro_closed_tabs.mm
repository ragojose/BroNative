// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "bro_closed_tabs.h"

#import "bro_persist.h"

@implementation BroClosedTabEntry
@end

// Large enough that a quit with a full strip of tabs doesn't evict the
// explicitly closed ones recorded before it.
static const NSUInteger kMaxClosedTabHistory = 25;
static NSString* const kBroClosedTabsFile = @"closed_tabs.json";

// Flat array on disk, oldest first, mirroring the in-memory order.
static void BroLoadClosedTabsInto(NSMutableArray<BroClosedTabEntry*>* list) {
  NSArray* saved = BroLoadJSONFile(kBroClosedTabsFile);
  if (![saved isKindOfClass:[NSArray class]]) {
    return;
  }
  for (NSDictionary* dict in saved) {
    if (![dict isKindOfClass:[NSDictionary class]]) {
      continue;
    }
    NSString* url = dict[@"url"];
    if (![url isKindOfClass:[NSString class]] || url.length == 0) {
      continue;
    }
    BroClosedTabEntry* entry = [[BroClosedTabEntry alloc] init];
    entry.url = url;
    NSString* title = dict[@"title"];
    entry.title = [title isKindOfClass:[NSString class]] ? title : @"";
    NSString* favicon = dict[@"faviconURL"];
    entry.faviconURL = [favicon isKindOfClass:[NSString class]] ? favicon : nil;
    [list addObject:entry];
    if (list.count >= kMaxClosedTabHistory) {
      break;
    }
  }
}

static NSMutableArray<BroClosedTabEntry*>* BroClosedTabsStorage(void) {
  static NSMutableArray<BroClosedTabEntry*>* list = nil;
  if (!list) {
    list = [NSMutableArray array];
    BroLoadClosedTabsInto(list);
  }
  return list;
}

// Every mutation saves synchronously: the list is tiny (≤25 rows) and the
// quit-time snapshot must be on disk before the process exits.
static void BroSaveClosedTabs(void) {
  NSMutableArray<NSDictionary*>* saved = [NSMutableArray array];
  for (BroClosedTabEntry* entry in BroClosedTabsStorage()) {
    NSMutableDictionary* dict = [NSMutableDictionary dictionary];
    dict[@"url"] = entry.url ?: @"";
    dict[@"title"] = entry.title ?: @"";
    if (entry.faviconURL.length > 0) {
      dict[@"faviconURL"] = entry.faviconURL;
    }
    [saved addObject:dict];
  }
  BroSaveJSONFile(kBroClosedTabsFile, saved);
}

void BroRecordClosedTab(NSString* url, NSString* title, NSString* faviconURL) {
  BroClosedTabEntry* entry = [[BroClosedTabEntry alloc] init];
  entry.url = url;
  entry.title = title;
  entry.faviconURL = faviconURL;
  NSMutableArray<BroClosedTabEntry*>* list = BroClosedTabsStorage();
  [list addObject:entry];
  if (list.count > kMaxClosedTabHistory) {
    [list removeObjectAtIndex:0];
  }
  BroSaveClosedTabs();
}

NSArray<BroClosedTabEntry*>* BroClosedTabsList(void) {
  return BroClosedTabsStorage();
}

NSUInteger BroClosedTabsCount(void) {
  return BroClosedTabsStorage().count;
}

void BroRemoveClosedTab(BroClosedTabEntry* entry) {
  [BroClosedTabsStorage() removeObject:entry];
  BroSaveClosedTabs();
}

void BroClearClosedTabs(void) {
  [BroClosedTabsStorage() removeAllObjects];
  BroSaveClosedTabs();
}
