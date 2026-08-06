// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#ifndef BRO_HANDLER_H_
#define BRO_HANDLER_H_

#include "include/cef_client.h"

#include <list>
#include <map>
#include <set>

// Forward declare UI callback functions (implemented in bro_mac.mm).
// All of these are invoked on the CEF UI thread, which is the main thread.
void UpdateNavigationState(bool canGoBack, bool canGoForward);
void UpdateURL(const std::string& url);
void SetLoading(bool loading);
// Adopts the browser as a tab if its native view lives in the tab container.
// Returns false for browsers hosted elsewhere (e.g. DevTools).
bool OnTabCreated(int browser_id, const std::string& url, void* native_view);
void OnTabTitleChanged(int browser_id, const std::string& title);
void OnTabURLChanged(int browser_id, const std::string& url);
void OnTabFaviconChanged(int browser_id, const std::string& favicon_url);
void OnTabClosed(int browser_id);
void OnActiveTabChanged(int browser_id);
void OnTabLoadingChanged(int browser_id, bool is_loading);
void OpenLinkInNewTab(const std::string& url);
// Detaches a tab's container view so CEF can finish destroying the browser.
void DetachTabView(int browser_id);
// True if the browser was adopted as a tab in the main window.
bool HasTabView(int browser_id);
// Creates a hidden tab container view for an incoming popup browser and
// returns its CefWindowHandle plus current bounds. Returns nullptr if no
// window is available to host it.
void* CreatePopupTabContainer(int popup_id, int* width, int* height);
// Removes a popup container that never received its browser (popup aborted).
void RemovePopupTabContainer(int popup_id);

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

  // Toggle mobile device emulation (viewport metrics, user agent, touch) for
  // a single tab via the DevTools protocol. Other tabs are unaffected.
  void SetTabMobileEmulation(int browser_id, bool enabled);
  bool IsTabMobile(int browser_id) const {
    return mobile_tab_ids_.count(browser_id) > 0;
  }

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
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser,
                            int popup_id) override;
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
  // Applies (or clears) the device emulation overrides on one browser.
  void ApplyEmulationToBrowser(CefRefPtr<CefBrowser> browser,
                               bool mobile,
                               bool reload);

  // True if using Alloy style (native windows)
  const bool is_alloy_style_;

  // Tabs with mobile device emulation active.
  std::set<int> mobile_tab_ids_;

  // List of existing browser windows.
  typedef std::list<CefRefPtr<CefBrowser>> BrowserList;
  BrowserList browser_list_;

  // Map of browser ID to browser for quick lookup
  typedef std::map<int, CefRefPtr<CefBrowser>> BrowserMap;
  BrowserMap browser_map_;

  // Active browser ID (current tab)
  int active_browser_id_ = -1;

  // True while CloseAllBrowsers is tearing everything down (window close /
  // app quit). Individual tab closes are handled by detaching the tab's view
  // in DoClose; the whole-window close goes through the OS close path.
  bool closing_all_ = false;

  bool is_closing_ = false;

  IMPLEMENT_REFCOUNTING(BroHandler);
  DISALLOW_COPY_AND_ASSIGN(BroHandler);
};

#endif  // BRO_HANDLER_H_
