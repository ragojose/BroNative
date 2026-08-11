// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "bro_handler.h"

#import <Cocoa/Cocoa.h>

#include "include/cef_browser.h"

namespace {

NSWindow* GetNSWindowForBrowser(CefRefPtr<CefBrowser> browser) {
  NSView* view =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  return [view window];
}

}  // namespace

void BroHandler::PlatformTitleChange(CefRefPtr<CefBrowser> browser,
                                     const CefString& title) {
  NSWindow* window = GetNSWindowForBrowser(browser);
  std::string titleStr(title);
  NSString* str = [NSString stringWithUTF8String:titleStr.c_str()];
  // Blank pages report "about:blank" as their title; the window title still
  // shows up in the Window menu and Mission Control, so name it like the tab.
  if (str.length == 0 || [str isEqualToString:@"about:blank"]) {
    str = @"New Tab";
  }
  [window setTitle:str];
}

void BroHandler::PlatformShowWindow(CefRefPtr<CefBrowser> browser) {
  NSWindow* window = GetNSWindowForBrowser(browser);
  [window makeKeyAndOrderFront:window];
}

void BroHandler::PlatformCopyToClipboard(const std::string& text) {
  NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  // Nil-coalesce like every other conversion site in this handler:
  // setString:forType: raises on nil.
  NSString* str = [NSString stringWithUTF8String:text.c_str()] ?: @"";
  [pasteboard setString:str forType:NSPasteboardTypeString];
}
