// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#ifndef BRO_HANDLER_H_
#define BRO_HANDLER_H_

#include "include/cef_client.h"

#include <list>
#include <map>

// Forward declare UI callback functions (implemented in bro_mac.mm)
void UpdateNavigationState(bool canGoBack, bool canGoForward);
void UpdateURL(const std::string& url);
void SetLoading(bool loading);
void OnTabCreated(int browser_id, const std::string& url);
void OnTabTitleChanged(int browser_id, const std::string& title);
void OnTabFaviconChanged(int browser_id, const std::string& favicon_url);
void OnTabClosed(int browser_id);
void OnActiveTabChanged(int browser_id);
void OnTabLoadingChanged(int browser_id, bool is_loading);
void OpenLinkInNewTab(const std::string& url);

class BroHandler : public CefClient,
                   public CefDisplayHandler,
                   public CefLifeSpanHandler,
                   public CefLoadHandler,
                   public CefContextMenuHandler {
 public:
  explicit BroHandler(bool is_alloy_style);
  ~BroHandler();

  // Provide access to the single global instance of this object.
  static BroHandler* GetInstance();

  // Get the active browser (current tab)
  CefRefPtr<CefBrowser> GetBrowser();

  // Get browser by ID
  CefRefPtr<CefBrowser> GetBrowserById(int browser_id);

  // Set the active browser (switch tabs)
  void SetActiveBrowser(int browser_id);

  // Get active browser ID
  int GetActiveBrowserId() const { return active_browser_id_; }

  // Close a specific browser (tab)
  void CloseBrowser(int browser_id);

  // CefClient methods:
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }

  // CefDisplayHandler methods:
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override;

  // CefLifeSpanHandler methods:
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefLoadHandler methods:
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override;

  // CefContextMenuHandler methods:
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override;
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags event_flags) override;

  // Request that all existing browser windows close.
  void CloseAllBrowsers(bool force_close);

  bool IsClosing() const { return is_closing_; }

  // Show the main window
  void ShowMainWindow();

  // Platform-specific title change
  void PlatformTitleChange(CefRefPtr<CefBrowser> browser,
                           const CefString& title);

  // Platform-specific show window
  void PlatformShowWindow(CefRefPtr<CefBrowser> browser);

 private:
  // True if using Alloy style (native windows)
  const bool is_alloy_style_;

  // List of existing browser windows.
  typedef std::list<CefRefPtr<CefBrowser>> BrowserList;
  BrowserList browser_list_;

  // Map of browser ID to browser for quick lookup
  typedef std::map<int, CefRefPtr<CefBrowser>> BrowserMap;
  BrowserMap browser_map_;

  // Active browser ID (current tab)
  int active_browser_id_ = -1;

  bool is_closing_ = false;

  IMPLEMENT_REFCOUNTING(BroHandler);
  DISALLOW_COPY_AND_ASSIGN(BroHandler);
};

#endif  // BRO_HANDLER_H_
