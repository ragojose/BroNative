// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "tab_description_fetcher.h"

#include "include/cef_parser.h"

TabDescriptionFetcher::TabDescriptionFetcher(
    CefDevToolsMessageObserver* observer)
    : observer_(observer) {}

void TabDescriptionFetcher::Fetch(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (!host) {
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

  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString(
      "expression",
      "(document.querySelector('meta[name=\"description\" i]') || {})"
      ".content || ''");
  params->SetBool("returnByValue", true);
  int message_id = host->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
  if (message_id != 0) {
    // Only the latest request per browser is tracked; a superseded in-flight
    // result is simply ignored in HandleMethodResult.
    pending_description_requests_[browser_id] = message_id;
  }
}

void TabDescriptionFetcher::HandleMethodResult(CefRefPtr<CefBrowser> browser,
                                               int message_id,
                                               bool success,
                                               const void* result,
                                               size_t result_size) {
  if (!browser) {
    return;
  }
  int browser_id = browser->GetIdentifier();
  auto it = pending_description_requests_.find(browser_id);
  if (it == pending_description_requests_.end() || it->second != message_id) {
    // Not ours (e.g. an emulation call's result routed to the same observer).
    return;
  }
  pending_description_requests_.erase(it);

  std::string description;
  if (success && result && result_size > 0) {
    // result is the CDP response's "result" payload:
    // {"result": {"type": "string", "value": "..."}}
    CefRefPtr<CefValue> parsed =
        CefParseJSON(result, result_size, JSON_PARSER_RFC);
    if (parsed && parsed->GetType() == VTYPE_DICTIONARY) {
      CefRefPtr<CefDictionaryValue> outer = parsed->GetDictionary();
      if (outer->HasKey("result") &&
          outer->GetType("result") == VTYPE_DICTIONARY) {
        CefRefPtr<CefDictionaryValue> inner = outer->GetDictionary("result");
        if (inner->HasKey("value") && inner->GetType("value") == VTYPE_STRING) {
          description = inner->GetString("value").ToString();
        }
      }
    }
  }
  // Deliver even when empty so the UI caches "no description" and doesn't
  // refetch on every hover.
  OnTabDescriptionAvailable(browser_id, description);
}

void TabDescriptionFetcher::OnBrowserClosed(int browser_id) {
  devtools_registrations_.erase(browser_id);
  pending_description_requests_.erase(browser_id);
}
