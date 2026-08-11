// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Browsing history: one entry per URL, Chrome-omnibox style — revisiting
// bumps visitCount and refreshes lastVisit instead of adding a row. Kept
// most-recent-last (append order == recency order) and persisted to
// history.json in the profile directory. Feeds the History menu's recents.

#ifndef BRO_HISTORY_H_
#define BRO_HISTORY_H_

#import <Cocoa/Cocoa.h>

@interface BroHistoryEntry : NSObject
@property(nonatomic, copy) NSString* url;
@property(nonatomic, copy) NSString* title;       // empty until backfilled
@property(nonatomic, copy) NSString* faviconURL;  // nil if never resolved
@property(nonatomic, assign) NSTimeInterval lastVisit;  // Unix epoch seconds
@property(nonatomic, assign) NSInteger visitCount;
@end

// Records a main-frame commit for |browser_id|. Skips blank and
// non-http(s) URLs (data: error pages, devtools:, file:) and consecutive
// repeats of the same URL in the same tab (fragment/reload spam).
void BroHistoryRecordVisit(int browser_id, NSString* url);

// Titles and favicons arrive after the URL commit; these backfill the entry
// if the URL is (still) in history. A stale pair racing a navigation no-ops
// harmlessly.
void BroHistoryUpdateTitle(NSString* url, NSString* title);
void BroHistoryUpdateFavicon(NSString* url, NSString* faviconURL);

// Drops the per-tab dedupe state for a closed tab.
void BroHistoryTabClosed(int browser_id);

// Most-recent-LAST; iterate in reverse for recency order.
NSArray<BroHistoryEntry*>* BroHistoryEntries(void);

// Flushes any debounced write immediately. Call on the quit paths — once
// CefQuitMessageLoop stops the loop, the pending debounce never fires.
void BroHistorySaveNow(void);

// Empties the store (and the file) after user confirmation.
void BroHistoryClear(void);

#endif  // BRO_HISTORY_H_
