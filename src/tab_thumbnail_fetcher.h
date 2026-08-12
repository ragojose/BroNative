// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#ifndef TAB_THUMBNAIL_FETCHER_H_
#define TAB_THUMBNAIL_FETCHER_H_

#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_registration.h"

#include <map>
#include <string>

// Delivers a page snapshot as base64-encoded JPEG data in response to
// TabThumbnailFetcher::Fetch (implemented in bro_mac.mm). Only called on
// success with non-empty data; failed captures deliver nothing so an older
// good snapshot is never clobbered.
void OnTabThumbnailAvailable(int browser_id, const std::string& jpeg_base64);

// Captures a snapshot of a tab's page via the DevTools protocol
// (Page.captureScreenshot over CefBrowserHost::ExecuteDevToolsMethod /
// CefDevToolsMessageObserver round trip) and delivers the result through
// OnTabThumbnailAvailable. Owns the per-browser DevTools observer
// registrations and in-flight request bookkeeping.
class TabThumbnailFetcher {
 public:
  // |observer| receives the raw DevTools method results (typically the
  // owning BroHandler, which implements CefDevToolsMessageObserver and
  // forwards its callback into HandleMethodResult()). Not owned; must
  // outlive this object.
  //
  // Note: BroHandler is registered as a DevTools observer by both this
  // fetcher and TabDescriptionFetcher, so CEF notifies it once per
  // registration — every CDP result reaches each fetcher twice. Harmless:
  // both filter by their own pending message id, and the duplicate call
  // finds the pending entry already erased.
  explicit TabThumbnailFetcher(CefDevToolsMessageObserver* observer);

  // Asynchronously captures a snapshot of |browser|'s page. Best-effort:
  // silently does nothing for blank pages or browsers without a host, and
  // never assumes the DevTools result callback fires (a capture issued
  // against a browser that just went hidden may never resolve).
  void Fetch(CefRefPtr<CefBrowser> browser);

  // Forwards a CefDevToolsMessageObserver::OnDevToolsMethodResult call here.
  // Parses the CDP response and delivers it via OnTabThumbnailAvailable if
  // |message_id| matches the in-flight request for |browser|.
  void HandleMethodResult(CefRefPtr<CefBrowser> browser,
                          int message_id,
                          bool success,
                          const void* result,
                          size_t result_size);

  // Drops all bookkeeping for |browser_id|. Call when the browser closes;
  // dropping the registration unregisters the DevTools observer, so no
  // capture results arrive for a dead browser.
  void OnBrowserClosed(int browser_id);

 private:
  CefDevToolsMessageObserver* observer_;  // Not owned.

  // Per-browser DevTools observer registrations (alive until the browser
  // closes) and the message id of each browser's in-flight capture request.
  std::map<int, CefRefPtr<CefRegistration>> devtools_registrations_;
  std::map<int, int> pending_thumbnail_requests_;
};

#endif  // TAB_THUMBNAIL_FETCHER_H_
