// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Recently closed tabs, oldest first, for Reopen Closed Tab (Cmd+Shift+T)
// and the tab search panel's "Recently Closed" section. Blank/new-tab pages
// are not recorded. The list is capped (oldest dropped) internally; callers
// never touch the backing store directly.

#ifndef BRO_CLOSED_TABS_H_
#define BRO_CLOSED_TABS_H_

#import <Cocoa/Cocoa.h>

@interface BroClosedTabEntry : NSObject
@property(nonatomic, copy) NSString* url;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* faviconURL;  // nil if never resolved
@end

// Records a closed tab. Caller is responsible for skipping blank/no-URL tabs
// (recording those isn't useful to reopen).
void BroRecordClosedTab(NSString* url, NSString* title, NSString* faviconURL);
// Oldest first, mirroring the original g_closed_tabs order.
NSArray<BroClosedTabEntry*>* BroClosedTabsList(void);
NSUInteger BroClosedTabsCount(void);
// Removes a specific entry (Reopen Closed Tab removes the most recent one;
// the search panel can reopen any row).
void BroRemoveClosedTab(BroClosedTabEntry* entry);
void BroClearClosedTabs(void);

#endif  // BRO_CLOSED_TABS_H_
