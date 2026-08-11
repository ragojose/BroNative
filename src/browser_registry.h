// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#ifndef BROWSER_REGISTRY_H_
#define BROWSER_REGISTRY_H_

#include "include/cef_browser.h"

#include <list>
#include <map>

// Owns the set of live browsers (tabs) and which one is active. No UI
// knowledge; callers translate registry state into UI updates.
class BrowserRegistry {
 public:
  BrowserRegistry() = default;

  // Adds |browser| to the registry.
  void Add(CefRefPtr<CefBrowser> browser);

  // Removes |browser| from the registry. Does not touch the active browser
  // id; call SelectNextActive() afterwards if the removed browser was
  // active.
  void Remove(CefRefPtr<CefBrowser> browser);

  // Returns the active browser, or the first browser if no active browser is
  // set, or null if the registry is empty.
  CefRefPtr<CefBrowser> GetActive() const;

  // Returns the browser with |browser_id|, or null if unknown.
  CefRefPtr<CefBrowser> GetById(int browser_id) const;

  // Sets the active browser id if |browser_id| is registered. Returns the
  // browser on success, null if |browser_id| is unknown (in which case the
  // active id is left unchanged).
  CefRefPtr<CefBrowser> SetActive(int browser_id);

  int active_id() const { return active_browser_id_; }

  // Picks a new active browser: the first entry in list order. Sets it as
  // active and returns it, or returns null (leaving the active id
  // unchanged) if the registry is empty.
  CefRefPtr<CefBrowser> SelectNextActive();

  bool empty() const { return browser_list_.empty(); }
  size_t size() const { return browser_list_.size(); }

  // Returns the first registered browser, or null if empty.
  CefRefPtr<CefBrowser> front() const;

  // Closes a single browser by id (not forced).
  void CloseBrowser(int browser_id);

  // Closes every registered browser.
  void CloseAll(bool force_close);

 private:
  typedef std::list<CefRefPtr<CefBrowser>> BrowserList;
  BrowserList browser_list_;

  typedef std::map<int, CefRefPtr<CefBrowser>> BrowserMap;
  BrowserMap browser_map_;

  int active_browser_id_ = -1;
};

#endif  // BROWSER_REGISTRY_H_
