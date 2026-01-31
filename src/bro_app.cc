// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "bro_app.h"

#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "bro_handler.h"

BroApp::BroApp() = default;

void BroApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  // Minimal flags - only what's needed for basic GPU acceleration
  command_line->AppendSwitch("enable-gpu");
  command_line->AppendSwitchWithValue("use-angle", "metal");
  command_line->AppendSwitch("ignore-gpu-blocklist");
}

void BroApp::OnContextInitialized() {
  CEF_REQUIRE_UI_THREAD();
  // Browser creation is handled in bro_mac.mm after the window is set up
}

CefRefPtr<CefClient> BroApp::GetDefaultClient() {
  return BroHandler::GetInstance();
}
