// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "browser_registry.h"

void BrowserRegistry::Add(CefRefPtr<CefBrowser> browser) {
  browser_list_.push_back(browser);
  browser_map_[browser->GetIdentifier()] = browser;
}

void BrowserRegistry::Remove(CefRefPtr<CefBrowser> browser) {
  for (auto it = browser_list_.begin(); it != browser_list_.end(); ++it) {
    if ((*it)->IsSame(browser)) {
      browser_list_.erase(it);
      break;
    }
  }
  browser_map_.erase(browser->GetIdentifier());
}

CefRefPtr<CefBrowser> BrowserRegistry::GetActive() const {
  // Return the active browser, or the first one if no active browser set.
  if (active_browser_id_ != -1) {
    auto it = browser_map_.find(active_browser_id_);
    if (it != browser_map_.end()) {
      return it->second;
    }
  }
  if (!browser_list_.empty()) {
    return browser_list_.front();
  }
  return nullptr;
}

CefRefPtr<CefBrowser> BrowserRegistry::GetById(int browser_id) const {
  auto it = browser_map_.find(browser_id);
  if (it != browser_map_.end()) {
    return it->second;
  }
  return nullptr;
}

CefRefPtr<CefBrowser> BrowserRegistry::SetActive(int browser_id) {
  auto it = browser_map_.find(browser_id);
  if (it == browser_map_.end()) {
    return nullptr;
  }
  active_browser_id_ = browser_id;
  return it->second;
}

CefRefPtr<CefBrowser> BrowserRegistry::SelectNextActive() {
  if (browser_list_.empty()) {
    return nullptr;
  }
  CefRefPtr<CefBrowser> browser = browser_list_.front();
  active_browser_id_ = browser->GetIdentifier();
  return browser;
}

CefRefPtr<CefBrowser> BrowserRegistry::front() const {
  if (browser_list_.empty()) {
    return nullptr;
  }
  return browser_list_.front();
}

void BrowserRegistry::CloseBrowser(int browser_id) {
  auto it = browser_map_.find(browser_id);
  if (it != browser_map_.end()) {
    it->second->GetHost()->CloseBrowser(false);
  }
}

void BrowserRegistry::CloseAll(bool force_close) {
  for (const auto& browser : browser_list_) {
    browser->GetHost()->CloseBrowser(force_close);
  }
}
