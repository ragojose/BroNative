// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Private shared header for the bro_mac.mm split family (bro_mac.mm,
// bro_favicon.mm, bro_downloads.mm, bro_toolbar.mm, bro_closed_tabs.mm,
// bro_tabsearch.mm, bro_tabstrip.mm). Declares the cross-file globals, the
// cross-file free functions, and the @class/@interface declarations that
// must be visible across the family. Not a public API -- nothing outside
// this file family should include it.

#ifndef BRO_MAC_INTERNAL_H_
#define BRO_MAC_INTERNAL_H_

#import <Cocoa/Cocoa.h>

#pragma mark - BroFaviconLoader

// Fetches and caches favicons off the main thread. Replaces the previous
// blocking -[NSImage initWithContentsOfURL:] which performed synchronous
// network I/O on a shared GCD queue with no cache, dedup, or timeout.
@interface BroFaviconLoader : NSObject
+ (instancetype)sharedLoader;
// Completion is always invoked on the main thread. Passes nil on failure.
- (void)fetchFavicon:(NSString*)urlString
          completion:(void (^)(NSImage* image))completion;
@end

#endif  // BRO_MAC_INTERNAL_H_
