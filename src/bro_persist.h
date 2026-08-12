// Copyright (c) 2013 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Tiny JSON-file persistence shared by the closed-tab list and the history
// store. Everything reads/writes small files in the profile directory.

#ifndef BRO_PERSIST_H_
#define BRO_PERSIST_H_

#import <Foundation/Foundation.h>

// App appearance is a user preference rather than a launch-time fiat. The
// enum values double as menu-item tags; persistence uses stable strings so a
// future reorder cannot reinterpret an existing profile.
typedef NS_ENUM(NSInteger, BroAppearancePreference) {
  BroAppearanceSystem = 0,
  BroAppearanceLight = 1,
  BroAppearanceDark = 2,
};

// Profile directory shared with CEF's cache: $BRO_USER_DATA_DIR when absolute
// (test harnesses run isolated instances concurrently), else ~/Library/
// Application Support/Bro. Created on first use; main() feeds the same path
// to CEF's cache settings.
NSString* BroUserDataDirectory(void);

// Reads <profile>/<filename> as JSON. Returns nil on any failure — a missing
// or corrupt file means "start fresh"; user data is never worth a crash.
id BroLoadJSONFile(NSString* filename);

// Writes synchronously on the caller's (main) thread. Both stores are small
// (≤25 closed tabs; history saves are debounced), and a synchronous write is
// the only kind guaranteed to land during quit — once CefQuitMessageLoop
// stops the loop, queued async work never runs.
void BroSaveJSONFile(NSString* filename, id obj);

// Stored in <profile>/preferences.json using the same atomic JSON path as the
// rest of Bro's small durable state. Missing/corrupt/unknown values resolve to
// System so first launch follows macOS.
BroAppearancePreference BroLoadAppearancePreference(void);
void BroSaveAppearancePreference(BroAppearancePreference preference);

#endif  // BRO_PERSIST_H_
