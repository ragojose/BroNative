// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "bro_handler.h"

#include <sstream>
#include <string>

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_parser.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

namespace {

BroHandler* g_instance = nullptr;

// Returns a data: URI with the specified contents.
std::string GetDataURI(const std::string& data, const std::string& mime_type) {
  return "data:" + mime_type + ";base64," +
         CefURIEncode(CefBase64Encode(data.data(), data.size()), false)
             .ToString();
}

// Escapes a string for safe interpolation into HTML.
std::string EscapeHTML(const std::string& text) {
  std::string result;
  result.reserve(text.size());
  for (char c : text) {
    switch (c) {
      case '&':  result += "&amp;"; break;
      case '<':  result += "&lt;"; break;
      case '>':  result += "&gt;"; break;
      case '"':  result += "&quot;"; break;
      case '\'': result += "&#39;"; break;
      default:   result += c; break;
    }
  }
  return result;
}

}  // namespace

BroHandler::BroHandler(bool is_alloy_style)
    : is_alloy_style_(is_alloy_style),
      tab_description_fetcher_(this),
      tab_thumbnail_fetcher_(this) {
  DCHECK(!g_instance);
  g_instance = this;
}

BroHandler::~BroHandler() {
  g_instance = nullptr;
}

// static
BroHandler* BroHandler::GetInstance() {
  return g_instance;
}

CefRefPtr<CefBrowser> BroHandler::GetBrowser() {
  return browser_registry_.GetActive();
}

CefRefPtr<CefBrowser> BroHandler::GetBrowserById(int browser_id) {
  return browser_registry_.GetById(browser_id);
}

void BroHandler::SetActiveBrowser(int browser_id) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI,
                base::BindOnce(&BroHandler::SetActiveBrowser, this, browser_id));
    return;
  }

  if (browser_id == browser_registry_.active_id()) {
    return;
  }

  // Snapshot the outgoing tab for its hover-card thumbnail while the
  // compositor surface still holds the on-screen frame; the capture resolves
  // asynchronously and tolerates the WasHidden that follows.
  tab_thumbnail_fetcher_.Fetch(
      browser_registry_.GetById(browser_registry_.active_id()));

  CefRefPtr<CefBrowser> browser = browser_registry_.SetActive(browser_id);
  if (browser) {
    OnActiveTabChanged(browser_id);

    // Update UI with the new active tab's state
    UpdateURL(browser->GetMainFrame()->GetURL().ToString());
    UpdateNavigationState(browser->CanGoBack(), browser->CanGoForward());
  }
}

void BroHandler::OnFindResult(CefRefPtr<CefBrowser> browser,
                              int identifier,
                              int count,
                              const CefRect& selectionRect,
                              int activeMatchOrdinal,
                              bool finalUpdate) {
  CEF_REQUIRE_UI_THREAD();
  if (browser) {
    BroUpdateFindResult(browser->GetIdentifier(), identifier, count,
                        activeMatchOrdinal);
  }
}

bool BroHandler::OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) {
  CEF_REQUIRE_UI_THREAD();
  // A blank tab's CEF view is detached behind the welcome state, so letting
  // the browser take focus (creation and navigation both request it) would
  // only tear keyboard focus away from the welcome input. Cancel it; loaded
  // tabs keep the default behavior.
  return browser && BroTabIsBlank(browser->GetIdentifier());
}

void BroHandler::SetBrowserHidden(int browser_id, bool hidden) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI, base::BindOnce(&BroHandler::SetBrowserHidden, this,
                                       browser_id, hidden));
    return;
  }

  CefRefPtr<CefBrowser> browser = browser_registry_.GetById(browser_id);
  if (browser) {
    browser->GetHost()->WasHidden(hidden);
  }
}

void BroHandler::CloseBrowser(int browser_id) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI,
                base::BindOnce(&BroHandler::CloseBrowser, this, browser_id));
    return;
  }

  browser_registry_.CloseBrowser(browser_id);
}

void BroHandler::SetTabMobileEmulation(int browser_id, bool enabled) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI, base::BindOnce(&BroHandler::SetTabMobileEmulation,
                                       this, browser_id, enabled));
    return;
  }

  if (IsTabMobile(browser_id) == enabled) {
    return;
  }
  if (enabled) {
    mobile_tab_ids_.insert(browser_id);
  } else {
    mobile_tab_ids_.erase(browser_id);
  }

  CefRefPtr<CefBrowser> browser = browser_registry_.GetById(browser_id);
  if (browser) {
    // No reload here: the caller reloads after the viewport animation so the
    // page load doesn't compete with the window animation for the main thread.
    ApplyEmulationToBrowser(browser, enabled, /*reload=*/false);
  }
}

void BroHandler::AdoptTabMobileEmulation(int browser_id) {
  CEF_REQUIRE_UI_THREAD();

  if (IsTabMobile(browser_id)) {
    return;
  }
  // Recorded synchronously: the caller lays the shell and the tab's container
  // out from this state in the same turn.
  mobile_tab_ids_.insert(browser_id);

  CefPostTask(TID_UI,
              base::BindOnce(&BroHandler::ApplyPendingMobileEmulation, this,
                             browser_id));
}

void BroHandler::ApplyPendingMobileEmulation(int browser_id) {
  CEF_REQUIRE_UI_THREAD();

  // The tab may have closed or been switched back to desktop while the task
  // was queued.
  if (!IsTabMobile(browser_id)) {
    return;
  }
  CefRefPtr<CefBrowser> browser = browser_registry_.GetById(browser_id);
  if (browser) {
    // No reload: a freshly adopted tab has not made its first user-driven
    // navigation yet, which is when the user agent override takes effect.
    ApplyEmulationToBrowser(browser, /*mobile=*/true, /*reload=*/false);
  }
}

void BroHandler::ReloadTab(int browser_id) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI,
                base::BindOnce(&BroHandler::ReloadTab, this, browser_id));
    return;
  }

  CefRefPtr<CefBrowser> browser = browser_registry_.GetById(browser_id);
  if (browser) {
    browser->Reload();
  }
}

void BroHandler::FetchTabDescription(int browser_id) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI, base::BindOnce(&BroHandler::FetchTabDescription, this,
                                       browser_id));
    return;
  }

  CefRefPtr<CefBrowser> browser = browser_registry_.GetById(browser_id);
  tab_description_fetcher_.Fetch(browser);
}

void BroHandler::FetchTabThumbnail(int browser_id) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI, base::BindOnce(&BroHandler::FetchTabThumbnail, this,
                                       browser_id));
    return;
  }

  CefRefPtr<CefBrowser> browser = browser_registry_.GetById(browser_id);
  tab_thumbnail_fetcher_.Fetch(browser);
}

void BroHandler::OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                        int message_id,
                                        bool success,
                                        const void* result,
                                        size_t result_size) {
  CEF_REQUIRE_UI_THREAD();
  tab_description_fetcher_.HandleMethodResult(browser, message_id, success,
                                              result, result_size);
  tab_thumbnail_fetcher_.HandleMethodResult(browser, message_id, success,
                                            result, result_size);
}

void BroHandler::ApplyEmulationToBrowser(CefRefPtr<CefBrowser> browser,
                                         bool mobile,
                                         bool reload) {
  if (!browser) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (!host) {
    return;
  }

  if (mobile) {
    CefRefPtr<CefDictionaryValue> metrics = CefDictionaryValue::Create();
    metrics->SetInt("width", 390);
    metrics->SetInt("height", 844);
    // 0 = use the device's real scale factor. Emulating an iPhone's 3x on a
    // 2x panel rasters ~2.25x the pixels actually displayed and makes mobile
    // mode visibly sluggish.
    metrics->SetDouble("deviceScaleFactor", 0.0);
    metrics->SetBool("mobile", true);
    host->ExecuteDevToolsMethod(0, "Emulation.setDeviceMetricsOverride",
                                metrics);

    CefRefPtr<CefDictionaryValue> ua = CefDictionaryValue::Create();
    ua->SetString("userAgent",
                  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
                  "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 "
                  "Mobile/15E148 Safari/604.1");
    ua->SetString("platform", "iPhone");
    host->ExecuteDevToolsMethod(0, "Emulation.setUserAgentOverride", ua);

    CefRefPtr<CefDictionaryValue> touch = CefDictionaryValue::Create();
    touch->SetBool("enabled", true);
    touch->SetInt("maxTouchPoints", 5);
    host->ExecuteDevToolsMethod(0, "Emulation.setTouchEmulationEnabled",
                                touch);
  } else {
    host->ExecuteDevToolsMethod(0, "Emulation.clearDeviceMetricsOverride",
                                nullptr);

    // An empty user agent clears the override.
    CefRefPtr<CefDictionaryValue> ua = CefDictionaryValue::Create();
    ua->SetString("userAgent", "");
    host->ExecuteDevToolsMethod(0, "Emulation.setUserAgentOverride", ua);

    CefRefPtr<CefDictionaryValue> touch = CefDictionaryValue::Create();
    touch->SetBool("enabled", false);
    host->ExecuteDevToolsMethod(0, "Emulation.setTouchEmulationEnabled",
                                touch);
  }

  if (reload) {
    // The user agent override only takes effect on the next navigation.
    browser->Reload();
  }
}

void BroHandler::OnTitleChange(CefRefPtr<CefBrowser> browser,
                               const CefString& title) {
  CEF_REQUIRE_UI_THREAD();

  int browser_id = browser->GetIdentifier();
  OnTabTitleChanged(browser_id, title.ToString());

  if (is_alloy_style_) {
    PlatformTitleChange(browser, title);
  }
}

void BroHandler::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefFrame> frame,
                                 const CefString& url) {
  CEF_REQUIRE_UI_THREAD();

  if (frame->IsMain()) {
    // Every tab pill shows its own URL's host.
    OnTabURLChanged(browser->GetIdentifier(), url.ToString());
    // The editable address field only tracks the active tab.
    if (browser->GetIdentifier() == browser_registry_.active_id()) {
      UpdateURL(url.ToString());
    }
  }
}

void BroHandler::OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                                    const std::vector<CefString>& icon_urls) {
  CEF_REQUIRE_UI_THREAD();

  int browser_id = browser->GetIdentifier();

  // Use the first favicon URL if available
  if (!icon_urls.empty()) {
    OnTabFaviconChanged(browser_id, icon_urls[0].ToString());
  }
}

bool BroHandler::OnBeforePopup(CefRefPtr<CefBrowser> browser,
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
                               bool* no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();

  // *no_javascript_access is intentionally left untouched (defaults to
  // false/allowed): popups are hosted as tabs that keep sharing
  // window.opener with their opener, so restricting JS access here would
  // break that relationship for no benefit.

  // Host the popup browser in a new tab instead of a bare native window.
  // Keeping the original popup navigation (rather than cancel-and-reopen)
  // preserves POST bodies, window.opener, and the window.open() return value.
  int width = 0;
  int height = 0;
  void* container = CreatePopupTabContainer(popup_id, &width, &height);
  if (container) {
    windowInfo.SetAsChild(static_cast<CefWindowHandle>(container),
                          CefRect(0, 0, width, height));
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  }
  return false;
}

void BroHandler::OnBeforePopupAborted(CefRefPtr<CefBrowser> browser,
                                      int popup_id) {
  CEF_REQUIRE_UI_THREAD();
  RemovePopupTabContainer(popup_id);
}

void BroHandler::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  int browser_id = browser->GetIdentifier();

  // Add to the registry.
  browser_registry_.Add(browser);

  // Adopt as a tab if the browser's view lives in the tab container. Every
  // browser that reaches this handler was created with this CefClient (tabs
  // and popups-becoming-tabs); DevTools browsers are opened with a null
  // client (see ShowDevTools) and never arrive here at all.
  bool adopted =
      OnTabCreated(browser_id, browser->GetMainFrame()->GetURL().ToString(),
                   browser->GetHost()->GetWindowHandle());
  if (adopted) {
    browser_registry_.SetActive(browser_id);
  }
}

bool BroHandler::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  int browser_id = browser->GetIdentifier();

  // The last browser closing means the app is going down; windowShouldClose
  // consults this to let the window go.
  if (browser_registry_.size() == 1) {
    is_closing_ = true;
  }

  // Every tab close — individual (tab X button, Cmd+W, window.close(),
  // DevTools protocol) or teardown — detaches the tab's container view so
  // CEF destroys the browser directly, never sending a close to the shared
  // window (which would close every tab). This includes the LAST browser:
  // as of CEF 151.3.16, returning false for a child-view browser no longer
  // closes its host window, so routing the last close through the window
  // stalled quit forever. When the final browser dies, OnBeforeClose quits
  // the message loop and the process exits without a formal window close.
  if (HasTabView(browser_id)) {
    DetachTabView(browser_id);
    return true;
  }

  // Non-tab browsers (e.g. DevTools windows) keep the default close path.
  return false;
}

void BroHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  int browser_id = browser->GetIdentifier();

  // Remove from the registry.
  browser_registry_.Remove(browser);
  mobile_tab_ids_.erase(browser_id);
  tab_description_fetcher_.OnBrowserClosed(browser_id);
  tab_thumbnail_fetcher_.OnBrowserClosed(browser_id);

  // Notify UI about tab closure
  OnTabClosed(browser_id);

  // If we closed the active browser, switch to another one
  if (browser_id == browser_registry_.active_id()) {
    // Only a browser with a live tab view can become the active tab (T1):
    // skip past any entry that has no tab view instead of blindly taking
    // the list front.
    CefRefPtr<CefBrowser> new_active =
        browser_registry_.SelectNextActive(&HasTabView);
    if (new_active) {
      OnActiveTabChanged(new_active->GetIdentifier());
    }
  }

  if (browser_registry_.empty()) {
    // All browser windows have closed. Quit the application message loop.
    CefQuitMessageLoop();
  }
}

void BroHandler::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                      bool isLoading,
                                      bool canGoBack,
                                      bool canGoForward) {
  CEF_REQUIRE_UI_THREAD();

  int browser_id = browser->GetIdentifier();

  // Update tab loading state for all tabs
  OnTabLoadingChanged(browser_id, isLoading);

  // Only update toolbar UI for the active tab
  if (browser_id == browser_registry_.active_id()) {
    UpdateNavigationState(canGoBack, canGoForward);
  }
}

void BroHandler::OnLoadError(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             ErrorCode errorCode,
                             const CefString& errorText,
                             const CefString& failedUrl) {
  CEF_REQUIRE_UI_THREAD();

  // Don't display an error for downloaded files.
  if (errorCode == ERR_ABORTED) {
    return;
  }

  // Display a load error message using a data: URI. Escape the URL and
  // error text: both can carry attacker-controlled content.
  std::stringstream ss;
  ss << "<html><body bgcolor=\"white\">"
        "<h2>Failed to load URL "
     << EscapeHTML(std::string(failedUrl)) << " with error "
     << EscapeHTML(std::string(errorText)) << " (" << errorCode
     << ").</h2></body></html>";

  frame->LoadURL(GetDataURI(ss.str(), "text/html"));
}

bool BroHandler::CanDownload(CefRefPtr<CefBrowser> browser,
                             const CefString& url,
                             const CefString& request_method) {
  CEF_REQUIRE_UI_THREAD();
  return true;
}

bool BroHandler::OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefDownloadItem> download_item,
                                  const CefString& suggested_name,
                                  CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();

  std::string name = suggested_name.ToString();
  if (name.empty()) {
    name = "download";
  }
  // An empty path would send the file to the default temp directory, so
  // always resolve an explicit target in ~/Downloads.
  const std::string path = ResolveDownloadTargetPath(name);
  active_download_ids_.insert(download_item->GetId());
  OnDownloadStarted(download_item->GetId(), name, path);
  callback->Continue(path, /*show_dialog=*/false);
  return true;
}

void BroHandler::OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefDownloadItem> download_item,
                                   CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();

  if (!download_item->IsValid()) {
    return;
  }
  const uint32_t id = download_item->GetId();
  if (active_download_ids_.count(id) == 0) {
    return;  // Fires before OnBeforeDownload too, and after terminal states.
  }
  if (download_item->IsComplete()) {
    active_download_ids_.erase(id);
    OnDownloadFinished(id, download_item->GetFullPath().ToString(), true);
  } else if (download_item->IsCanceled() || download_item->IsInterrupted()) {
    active_download_ids_.erase(id);
    OnDownloadFinished(id, download_item->GetFullPath().ToString(), false);
  } else {
    OnDownloadProgress(id, download_item->GetReceivedBytes(),
                       download_item->GetTotalBytes());
  }
}

// Custom menu command IDs
enum ContextMenuIds {
  MENU_ID_OPEN_LINK_NEW_TAB = MENU_ID_USER_FIRST,
  MENU_ID_COPY_LINK,
  MENU_ID_COPY_IMAGE,
  MENU_ID_SAVE_IMAGE,
};

void BroHandler::OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefContextMenuParams> params,
                                     CefRefPtr<CefMenuModel> model) {
  CEF_REQUIRE_UI_THREAD();

  // Clear the default menu
  model->Clear();

  // Get context type flags
  cef_context_menu_type_flags_t type_flags = params->GetTypeFlags();

  // Link context
  if (type_flags & CM_TYPEFLAG_LINK) {
    model->AddItem(MENU_ID_OPEN_LINK_NEW_TAB, "Open Link in New Tab");
    model->AddItem(MENU_ID_COPY_LINK, "Copy Link");
    model->AddSeparator();
  }

  // Image context
  if (type_flags & CM_TYPEFLAG_MEDIA && params->GetMediaType() == CM_MEDIATYPE_IMAGE) {
    model->AddItem(MENU_ID_COPY_IMAGE, "Copy Image");
    model->AddItem(MENU_ID_SAVE_IMAGE, "Save Image As...");
    model->AddSeparator();
  }

  // Selection context
  if (type_flags & CM_TYPEFLAG_SELECTION) {
    model->AddItem(MENU_ID_COPY, "Copy");
    model->AddSeparator();
  }

  // Editable context
  if (type_flags & CM_TYPEFLAG_EDITABLE) {
    model->AddItem(MENU_ID_UNDO, "Undo");
    model->AddItem(MENU_ID_REDO, "Redo");
    model->AddSeparator();
    model->AddItem(MENU_ID_CUT, "Cut");
    model->AddItem(MENU_ID_COPY, "Copy");
    model->AddItem(MENU_ID_PASTE, "Paste");
    model->AddSeparator();
    model->AddItem(MENU_ID_SELECT_ALL, "Select All");
  } else if (!(type_flags & CM_TYPEFLAG_LINK) &&
             !(type_flags & CM_TYPEFLAG_MEDIA) &&
             !(type_flags & CM_TYPEFLAG_SELECTION)) {
    // Page context (empty area)
    model->AddItem(MENU_ID_BACK, "Back");
    model->AddItem(MENU_ID_FORWARD, "Forward");
    model->AddItem(MENU_ID_RELOAD, "Reload");
  }
}

bool BroHandler::OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      CefRefPtr<CefContextMenuParams> params,
                                      int command_id,
                                      EventFlags event_flags) {
  CEF_REQUIRE_UI_THREAD();

  switch (command_id) {
    case MENU_ID_OPEN_LINK_NEW_TAB: {
      // Create a new tab with the link URL
      std::string url = params->GetLinkUrl().ToString();
      OpenLinkInNewTab(url);
      return true;
    }
    case MENU_ID_COPY_LINK: {
      // The menu is rebuilt from scratch with custom IDs, so there is no CEF
      // default handler to fall through to; copy it ourselves.
      std::string url = params->GetLinkUrl().ToString();
      PlatformCopyToClipboard(url);
      return true;
    }
    case MENU_ID_BACK:
      if (browser->CanGoBack()) {
        browser->GoBack();
      }
      return true;
    case MENU_ID_FORWARD:
      if (browser->CanGoForward()) {
        browser->GoForward();
      }
      return true;
    case MENU_ID_RELOAD:
      browser->Reload();
      return true;
    default:
      return false;  // Default handling
  }
}

void BroHandler::ShowMainWindow() {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI, base::BindOnce(&BroHandler::ShowMainWindow, this));
    return;
  }

  if (browser_registry_.empty()) {
    return;
  }

  auto main_browser = browser_registry_.front();
  if (is_alloy_style_) {
    PlatformShowWindow(main_browser);
  }
}

void BroHandler::CloseAllBrowsers(bool force_close) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI,
                base::BindOnce(&BroHandler::CloseAllBrowsers, this, force_close));
    return;
  }

  if (browser_registry_.empty()) {
    return;
  }

  closing_all_ = true;

  browser_registry_.CloseAll(force_close);
}
