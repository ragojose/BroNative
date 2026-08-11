// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "bro_history.h"

#import "bro_persist.h"

@implementation BroHistoryEntry
@end

static const NSUInteger kMaxHistoryEntries = 3000;
static NSString* const kBroHistoryFile = @"history.json";

// url -> entry, for O(1) revisit upserts. Same objects as BroHistoryList().
static NSMutableDictionary<NSString*, BroHistoryEntry*>* BroHistoryIndex(void) {
  static NSMutableDictionary<NSString*, BroHistoryEntry*>* index = nil;
  if (!index) {
    index = [NSMutableDictionary dictionary];
  }
  return index;
}

// Versioned wrapper (unlike the flat closed-tabs file) because this store is
// expected to evolve — e.g. growing per-visit timestamps or moving to sqlite.
static NSMutableArray<BroHistoryEntry*>* BroHistoryList(void) {
  static NSMutableArray<BroHistoryEntry*>* list = nil;
  if (!list) {
    list = [NSMutableArray array];
    NSDictionary* root = BroLoadJSONFile(kBroHistoryFile);
    NSArray* saved =
        [root isKindOfClass:[NSDictionary class]] ? root[@"entries"] : nil;
    if ([saved isKindOfClass:[NSArray class]]) {
      for (NSDictionary* dict in saved) {
        if (![dict isKindOfClass:[NSDictionary class]]) {
          continue;
        }
        NSString* url = dict[@"url"];
        if (![url isKindOfClass:[NSString class]] || url.length == 0 ||
            BroHistoryIndex()[url] != nil) {
          continue;
        }
        BroHistoryEntry* entry = [[BroHistoryEntry alloc] init];
        entry.url = url;
        NSString* title = dict[@"title"];
        entry.title = [title isKindOfClass:[NSString class]] ? title : @"";
        NSString* favicon = dict[@"faviconURL"];
        entry.faviconURL =
            [favicon isKindOfClass:[NSString class]] ? favicon : nil;
        NSNumber* lastVisit = dict[@"lastVisit"];
        entry.lastVisit = [lastVisit isKindOfClass:[NSNumber class]]
                              ? lastVisit.doubleValue
                              : 0;
        NSNumber* visitCount = dict[@"visitCount"];
        entry.visitCount = [visitCount isKindOfClass:[NSNumber class]]
                               ? MAX(1, visitCount.integerValue)
                               : 1;
        [list addObject:entry];
        BroHistoryIndex()[url] = entry;
        if (list.count >= kMaxHistoryEntries) {
          break;
        }
      }
    }
  }
  return list;
}

NSArray<BroHistoryEntry*>* BroHistoryEntries(void) {
  return BroHistoryList();
}

void BroHistorySaveNow(void) {
  NSMutableArray<NSDictionary*>* saved = [NSMutableArray array];
  for (BroHistoryEntry* entry in BroHistoryList()) {
    NSMutableDictionary* dict = [NSMutableDictionary dictionary];
    dict[@"url"] = entry.url ?: @"";
    dict[@"title"] = entry.title ?: @"";
    if (entry.faviconURL.length > 0) {
      dict[@"faviconURL"] = entry.faviconURL;
    }
    dict[@"lastVisit"] = @(entry.lastVisit);
    dict[@"visitCount"] = @(entry.visitCount);
    [saved addObject:dict];
  }
  BroSaveJSONFile(kBroHistoryFile, @{@"version" : @1, @"entries" : saved});
}

// Debounced save: visits arrive in bursts (redirect chains, link clicking
// sprees), and each rewrite serializes the whole store.
static BOOL g_history_save_pending = NO;
static void BroHistoryScheduleSave(void) {
  if (g_history_save_pending) {
    return;
  }
  g_history_save_pending = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   g_history_save_pending = NO;
                   BroHistorySaveNow();
                 });
}

// Last URL recorded per tab, so same-document navigations (fragments, SPA
// pushState back to the same URL) and reload spam don't bump visit counts.
static NSMutableDictionary<NSNumber*, NSString*>* g_last_recorded_url = nil;

void BroHistoryRecordVisit(int browser_id, NSString* url) {
  if (url.length == 0 || [url isEqualToString:@"about:blank"]) {
    return;
  }
  // http(s) only: excludes the data: error page OnLoadError swaps in, plus
  // devtools:, file:, chrome: — none of which belong in history.
  NSString* scheme = [NSURL URLWithString:url].scheme.lowercaseString;
  if (!([scheme isEqualToString:@"http"] ||
        [scheme isEqualToString:@"https"])) {
    return;
  }
  if (!g_last_recorded_url) {
    g_last_recorded_url = [NSMutableDictionary dictionary];
  }
  if ([g_last_recorded_url[@(browser_id)] isEqualToString:url]) {
    return;
  }
  g_last_recorded_url[@(browser_id)] = url;

  NSMutableArray<BroHistoryEntry*>* list = BroHistoryList();
  BroHistoryEntry* entry = BroHistoryIndex()[url];
  if (entry) {
    entry.visitCount += 1;
    [list removeObjectIdenticalTo:entry];
  } else {
    entry = [[BroHistoryEntry alloc] init];
    entry.url = url;
    entry.title = @"";
    entry.visitCount = 1;
    BroHistoryIndex()[url] = entry;
  }
  entry.lastVisit = [NSDate date].timeIntervalSince1970;
  [list addObject:entry];
  while (list.count > kMaxHistoryEntries) {
    BroHistoryEntry* oldest = list.firstObject;
    [BroHistoryIndex() removeObjectForKey:oldest.url ?: @""];
    [list removeObjectAtIndex:0];
  }
  BroHistoryScheduleSave();
}

void BroHistoryUpdateTitle(NSString* url, NSString* title) {
  BroHistoryEntry* entry = url.length > 0 ? BroHistoryIndex()[url] : nil;
  if (!entry || title.length == 0 || [entry.title isEqualToString:title]) {
    return;
  }
  entry.title = title;
  BroHistoryScheduleSave();
}

void BroHistoryUpdateFavicon(NSString* url, NSString* faviconURL) {
  BroHistoryEntry* entry = url.length > 0 ? BroHistoryIndex()[url] : nil;
  if (!entry || faviconURL.length == 0 ||
      [entry.faviconURL isEqualToString:faviconURL]) {
    return;
  }
  entry.faviconURL = faviconURL;
  BroHistoryScheduleSave();
}

void BroHistoryTabClosed(int browser_id) {
  [g_last_recorded_url removeObjectForKey:@(browser_id)];
}

void BroHistoryClear(void) {
  [BroHistoryList() removeAllObjects];
  [BroHistoryIndex() removeAllObjects];
  [g_last_recorded_url removeAllObjects];
  BroHistorySaveNow();
}
