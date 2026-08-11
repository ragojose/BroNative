// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "bro_app.h"

#include <string>

#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "bro_handler.h"

BroApp::BroApp() = default;

void BroApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  // Only modify the browser process command line; switches propagate to
  // child processes automatically.
  if (!process_type.empty()) {
    return;
  }

  // Minimal flags - only what's needed for basic GPU acceleration. This set
  // was chosen after aggressive flags broke form submissions and navigation;
  // do not add feature-forcing switches here. WebAssembly (SIMD, GC, tiering,
  // code caching) and BackForwardCache are already enabled by default in
  // Chromium and need no flags.
  command_line->AppendSwitch("enable-gpu");
  command_line->AppendSwitchWithValue("use-angle", "metal");
  command_line->AppendSwitch("ignore-gpu-blocklist");

  // Chrome's Reading Mode ships in CEF without the profile plumbing it
  // expects: its ReadAnythingSoftNavigationObserver dereferences a null
  // coordinator the moment any page performs a soft navigation (History API /
  // same-document), taking the whole browser process down. Symbolicated from
  // a field crash on wakawaka.world, 2026-08-11 (build 85). Disabling the
  // feature removes the observer; merge with any existing list rather than
  // clobbering the features CEF disables on its own.
  const char kDisableFeatures[] = "disable-features";
  std::string disabled =
      command_line->HasSwitch(kDisableFeatures)
          ? command_line->GetSwitchValue(kDisableFeatures).ToString()
          : std::string();
  if (!disabled.empty()) {
    disabled += ",";
  }
  disabled += "ReadAnything";
  command_line->AppendSwitchWithValue(kDisableFeatures, disabled);
}

void BroApp::OnContextInitialized() {
  CEF_REQUIRE_UI_THREAD();
  // Browser creation is handled in bro_mac.mm after the window is set up
}

CefRefPtr<CefClient> BroApp::GetDefaultClient() {
  return BroHandler::GetInstance();
}
