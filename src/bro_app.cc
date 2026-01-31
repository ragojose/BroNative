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
  // Enable GPU acceleration and WebGL/WebGPU support

  // Enable hardware acceleration
  command_line->AppendSwitch("enable-gpu");
  command_line->AppendSwitch("enable-gpu-rasterization");

  // Enable WebGL
  command_line->AppendSwitch("enable-webgl");
  command_line->AppendSwitch("enable-webgl2-compute-context");

  // Enable WebGPU
  command_line->AppendSwitch("enable-unsafe-webgpu");
  command_line->AppendSwitch("enable-features=Vulkan,WebGPU");

  // Use ANGLE for WebGL on macOS (better compatibility)
  command_line->AppendSwitchWithValue("use-angle", "metal");

  // Enable zero-copy for better performance
  command_line->AppendSwitch("enable-zero-copy");

  // Disable some restrictions that might block GPU features
  command_line->AppendSwitch("ignore-gpu-blocklist");
  command_line->AppendSwitch("disable-gpu-driver-bug-workarounds");

  // Enable accelerated 2D canvas
  command_line->AppendSwitch("enable-accelerated-2d-canvas");

  // For macOS-specific GPU improvements
  command_line->AppendSwitch("use-mock-keychain");
}

void BroApp::OnContextInitialized() {
  CEF_REQUIRE_UI_THREAD();
  // Browser creation is handled in bro_mac.mm after the window is set up
}

CefRefPtr<CefClient> BroApp::GetDefaultClient() {
  return BroHandler::GetInstance();
}
