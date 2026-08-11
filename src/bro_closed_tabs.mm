// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "bro_closed_tabs.h"

@implementation BroClosedTabEntry
@end

static const NSUInteger kMaxClosedTabHistory = 10;

static NSMutableArray<BroClosedTabEntry*>* BroClosedTabsStorage(void) {
  static NSMutableArray<BroClosedTabEntry*>* list = nil;
  if (!list) {
    list = [NSMutableArray array];
  }
  return list;
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
}

NSArray<BroClosedTabEntry*>* BroClosedTabsList(void) {
  return BroClosedTabsStorage();
}

NSUInteger BroClosedTabsCount(void) {
  return BroClosedTabsStorage().count;
}

void BroRemoveClosedTab(BroClosedTabEntry* entry) {
  [BroClosedTabsStorage() removeObject:entry];
}

void BroClearClosedTabs(void) {
  [BroClosedTabsStorage() removeAllObjects];
}
