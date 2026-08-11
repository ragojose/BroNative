// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "bro_mac_internal.h"

#pragma mark - BroFaviconLoader

@implementation BroFaviconLoader {
  NSURLSession* session_;
  NSCache<NSString*, NSImage*>* cache_;
  // URLs that recently failed; skipped so a 404 favicon isn't refetched on
  // every navigation.
  NSMutableSet<NSString*>* failed_;
  // In-flight dedup: completions waiting on a URL already being fetched.
  // Main-thread only.
  NSMutableDictionary<NSString*, NSMutableArray<void (^)(NSImage*)>*>* inflight_;
}

+ (instancetype)sharedLoader {
  static BroFaviconLoader* shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[BroFaviconLoader alloc] init];
  });
  return shared;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    NSURLSessionConfiguration* config =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // Favicons must never hold sockets long.
    config.timeoutIntervalForRequest = 8;
    config.timeoutIntervalForResource = 15;
    session_ = [NSURLSession sessionWithConfiguration:config];
    cache_ = [[NSCache alloc] init];
    cache_.countLimit = 100;
    failed_ = [NSMutableSet set];
    inflight_ = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)fetchFavicon:(NSString*)urlString
          completion:(void (^)(NSImage*))completion {
  NSImage* cached = [cache_ objectForKey:urlString];
  if (cached) {
    completion(cached);
    return;
  }
  if ([failed_ containsObject:urlString]) {
    completion(nil);
    return;
  }
  NSURL* url = [NSURL URLWithString:urlString];
  if (!url) {
    completion(nil);
    return;
  }

  NSMutableArray* waiters = inflight_[urlString];
  if (waiters) {
    [waiters addObject:[completion copy]];
    return;
  }
  inflight_[urlString] = [NSMutableArray arrayWithObject:[completion copy]];

  NSURLSessionDataTask* task = [session_
        dataTaskWithURL:url
      completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        // Decode off-main on the session's queue; only delivery hops to main.
        NSImage* image = nil;
        if (!error && data.length > 0) {
          image = [[NSImage alloc] initWithData:data];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          if (image) {
            [self->cache_ setObject:image forKey:urlString];
          } else {
            [self->failed_ addObject:urlString];
          }
          NSArray* pending = self->inflight_[urlString];
          [self->inflight_ removeObjectForKey:urlString];
          for (void (^waiter)(NSImage*) in pending) {
            waiter(image);
          }
        });
      }];
  [task resume];
}

@end
