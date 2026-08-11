// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#ifndef TAB_DESCRIPTION_FETCHER_H_
#define TAB_DESCRIPTION_FETCHER_H_

#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_registration.h"

#include <map>
#include <string>

// Delivers the page's <meta name=description> content (possibly empty) in
// response to TabDescriptionFetcher::Fetch (implemented in bro_mac.mm).
void OnTabDescriptionAvailable(int browser_id, const std::string& description);

// Fetches a tab's <meta name=description> via the DevTools protocol
// (CefBrowserHost::ExecuteDevToolsMethod / CefDevToolsMessageObserver round
// trip) and delivers the result through OnTabDescriptionAvailable. Owns the
// per-browser DevTools observer registrations and in-flight request
// bookkeeping.
class TabDescriptionFetcher {
 public:
  // |observer| receives the raw DevTools method results (typically the
  // owning BroHandler, which implements CefDevToolsMessageObserver and
  // forwards its callback into HandleMethodResult()). Not owned; must
  // outlive this object.
  explicit TabDescriptionFetcher(CefDevToolsMessageObserver* observer);

  // Asynchronously fetches |browser|'s <meta name=description>. Best-effort:
  // silently does nothing if the browser has no host, and never assumes the
  // DevTools result callback fires.
  void Fetch(CefRefPtr<CefBrowser> browser);

  // Forwards a CefDevToolsMessageObserver::OnDevToolsMethodResult call here.
  // Parses the CDP response and delivers it via OnTabDescriptionAvailable if
  // |message_id| matches the in-flight request for |browser|.
  void HandleMethodResult(CefRefPtr<CefBrowser> browser,
                          int message_id,
                          bool success,
                          const void* result,
                          size_t result_size);

  // Drops all bookkeeping for |browser_id|. Call when the browser closes;
  // dropping the registration unregisters the DevTools observer, so no
  // description results arrive for a dead browser.
  void OnBrowserClosed(int browser_id);

 private:
  CefDevToolsMessageObserver* observer_;  // Not owned.

  // Per-browser DevTools observer registrations (alive until the browser
  // closes) and the message id of each browser's in-flight meta-description
  // request.
  std::map<int, CefRefPtr<CefRegistration>> devtools_registrations_;
  std::map<int, int> pending_description_requests_;
};

#endif  // TAB_DESCRIPTION_FETCHER_H_
