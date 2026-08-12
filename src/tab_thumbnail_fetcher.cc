// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "tab_thumbnail_fetcher.h"

#include "include/cef_parser.h"

TabThumbnailFetcher::TabThumbnailFetcher(CefDevToolsMessageObserver* observer)
    : observer_(observer) {}

void TabThumbnailFetcher::Fetch(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (!host) {
    return;
  }
  // Blank pages have nothing worth snapshotting; the hover card shows its
  // "New Tab" variant for them anyway.
  CefRefPtr<CefFrame> frame = browser->GetMainFrame();
  std::string url = frame ? frame->GetURL().ToString() : std::string();
  if (url.empty() || url == "about:blank") {
    return;
  }
  int browser_id = browser->GetIdentifier();

  // Register the observer for this browser once; the registration stays
  // alive until the browser closes (OnBrowserClosed erases it).
  if (devtools_registrations_.find(browser_id) ==
      devtools_registrations_.end()) {
    CefRefPtr<CefRegistration> registration =
        host->AddDevToolsMessageObserver(observer_);
    if (!registration) {
      return;
    }
    devtools_registrations_[browser_id] = registration;
  }

  // Captures the compositor's last surface frame (fromSurface defaults to
  // true), so a capture issued just before the browser is hidden still
  // resolves against the frame that was on screen.
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "jpeg");
  params->SetInt("quality", 70);
  int message_id =
      host->ExecuteDevToolsMethod(0, "Page.captureScreenshot", params);
  if (message_id != 0) {
    // Only the latest request per browser is tracked; a superseded in-flight
    // result is simply ignored in HandleMethodResult.
    pending_thumbnail_requests_[browser_id] = message_id;
  }
}

void TabThumbnailFetcher::HandleMethodResult(CefRefPtr<CefBrowser> browser,
                                             int message_id,
                                             bool success,
                                             const void* result,
                                             size_t result_size) {
  if (!browser) {
    return;
  }
  int browser_id = browser->GetIdentifier();
  auto it = pending_thumbnail_requests_.find(browser_id);
  if (it == pending_thumbnail_requests_.end() || it->second != message_id) {
    // Not ours (e.g. a description fetch's result routed to the same
    // observer).
    return;
  }
  pending_thumbnail_requests_.erase(it);

  if (!success || !result || result_size == 0) {
    return;
  }
  // result is the CDP response's payload: {"data": "<base64 jpeg>"} — flat,
  // unlike Runtime.evaluate's nested result.value.
  CefRefPtr<CefValue> parsed =
      CefParseJSON(result, result_size, JSON_PARSER_RFC);
  if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) {
    return;
  }
  CefRefPtr<CefDictionaryValue> dict = parsed->GetDictionary();
  if (!dict->HasKey("data") || dict->GetType("data") != VTYPE_STRING) {
    return;
  }
  std::string data = dict->GetString("data").ToString();
  // Failures deliver nothing (unlike descriptions, which cache "none"): the
  // UI keeps any older snapshot and the next trigger simply retries.
  if (!data.empty()) {
    OnTabThumbnailAvailable(browser_id, data);
  }
}

void TabThumbnailFetcher::OnBrowserClosed(int browser_id) {
  devtools_registrations_.erase(browser_id);
  pending_thumbnail_requests_.erase(browser_id);
}
