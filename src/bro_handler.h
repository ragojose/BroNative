// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#ifndef BRO_HANDLER_H_
#define BRO_HANDLER_H_

#include "browser_registry.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_registration.h"

#include <map>
#include <set>

// Forward declare UI callback functions (implemented in bro_mac.mm).
// All of these are invoked on the CEF UI thread, which is the main thread.
void UpdateNavigationState(bool canGoBack, bool canGoForward);
void UpdateURL(const std::string& url);
// Adopts the browser as a tab if its native view lives in the tab container.
// Returns false for browsers hosted elsewhere (e.g. DevTools).
bool OnTabCreated(int browser_id, const std::string& url, void* native_view);
void OnTabTitleChanged(int browser_id, const std::string& title);
// Delivers the page's <meta name=description> content (possibly empty) in
// response to FetchTabDescription.
void OnTabDescriptionAvailable(int browser_id, const std::string& description);
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
// Downloads. |download_id| is CefDownloadItem::GetId().
void OnDownloadStarted(uint32_t download_id,
                       const std::string& file_name,
                       const std::string& full_path);
void OnDownloadProgress(uint32_t download_id,
                        int64_t received_bytes,
                        int64_t total_bytes);
// |success| is false for canceled or interrupted downloads. |full_path| is
// the final on-disk path reported by CEF.
void OnDownloadFinished(uint32_t download_id,
                        const std::string& full_path,
                        bool success);
// Returns a unique, not-yet-existing target path in ~/Downloads for
// |suggested_name| ("name (2).ext" style).
std::string ResolveDownloadTargetPath(const std::string& suggested_name);

class BroHandler : public CefClient,
                   public CefDisplayHandler,
                   public CefLifeSpanHandler,
                   public CefLoadHandler,
                   public CefContextMenuHandler,
                   public CefDownloadHandler,
                   public CefDevToolsMessageObserver {
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
  int GetActiveBrowserId() const { return browser_registry_.active_id(); }

  // Close a specific browser (tab)
  void CloseBrowser(int browser_id);

  // Tell the browser whether its view is effectively visible so background
  // tabs throttle rendering and timers (hiding the parent NSView alone does
  // not reach Chromium's occlusion tracking in windowed CEF).
  void SetBrowserHidden(int browser_id, bool hidden);

  // Toggle mobile device emulation (viewport metrics, user agent, touch) for
  // a single tab via the DevTools protocol. Other tabs are unaffected.
  void SetTabMobileEmulation(int browser_id, bool enabled);
  bool IsTabMobile(int browser_id) const {
    return mobile_tab_ids_.count(browser_id) > 0;
  }

  // Reload a tab. Used to apply a pending user agent override once the
  // viewport toggle animation has finished (the UA only takes effect on the
  // next navigation).
  void ReloadTab(int browser_id);

  // Asynchronously fetches the tab's <meta name=description> via the DevTools
  // protocol; the result arrives through OnTabDescriptionAvailable.
  // Best-effort: silently does nothing if the browser is gone, and never
  // assumes the DevTools result callback fires.
  void FetchTabDescription(int browser_id);

  // CefClient methods:
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

  // CefDisplayHandler methods:
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override;

  // CefDevToolsMessageObserver methods:
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void* result,
                              size_t result_size) override;

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

  // CefDownloadHandler methods:
  bool CanDownload(CefRefPtr<CefBrowser> browser,
                   const CefString& url,
                   const CefString& request_method) override;
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;

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

  // Writes |text| to the system clipboard (used by the "Copy Link" context
  // menu item; custom menu IDs get no default handler from CEF).
  void PlatformCopyToClipboard(const std::string& text);

 private:
  // Applies (or clears) the device emulation overrides on one browser.
  void ApplyEmulationToBrowser(CefRefPtr<CefBrowser> browser,
                               bool mobile,
                               bool reload);

  // True if using Alloy style (native windows)
  const bool is_alloy_style_;

  // Tabs with mobile device emulation active.
  std::set<int> mobile_tab_ids_;

  // Downloads that passed OnBeforeDownload and are not yet in a terminal
  // state. Gates OnDownloadUpdated, which also fires before OnBeforeDownload.
  std::set<uint32_t> active_download_ids_;

  // Per-browser DevTools observer registrations (alive until the browser
  // closes) and the message id of each browser's in-flight meta-description
  // request.
  std::map<int, CefRefPtr<CefRegistration>> devtools_registrations_;
  std::map<int, int> pending_description_requests_;

  // Live browsers (tabs) and which one is active.
  BrowserRegistry browser_registry_;

  // True while CloseAllBrowsers is tearing everything down (window close /
  // app quit). Individual tab closes are handled by detaching the tab's view
  // in DoClose; the whole-window close goes through the OS close path.
  bool closing_all_ = false;

  bool is_closing_ = false;

  IMPLEMENT_REFCOUNTING(BroHandler);
  DISALLOW_COPY_AND_ASSIGN(BroHandler);
};

#endif  // BRO_HANDLER_H_
