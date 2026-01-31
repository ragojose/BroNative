// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#ifndef BRO_APP_H_
#define BRO_APP_H_

#include "include/cef_app.h"

// Implements application-level callbacks for the browser process.
class BroApp : public CefApp, public CefBrowserProcessHandler {
 public:
  BroApp();

  // CefApp methods:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override;

  // CefBrowserProcessHandler methods:
  void OnContextInitialized() override;
  CefRefPtr<CefClient> GetDefaultClient() override;

 private:
  IMPLEMENT_REFCOUNTING(BroApp);
  DISALLOW_COPY_AND_ASSIGN(BroApp);
};

#endif  // BRO_APP_H_
