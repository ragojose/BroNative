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

}  // namespace

BroHandler::BroHandler(bool is_alloy_style) : is_alloy_style_(is_alloy_style) {
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
  // Return the active browser, or the first one if no active browser set
  if (active_browser_id_ != -1) {
    auto it = browser_map_.find(active_browser_id_);
    if (it != browser_map_.end()) {
      return it->second;
    }
  }
  if (!browser_list_.empty()) {
    return browser_list_.front();
  }
  return nullptr;
}

CefRefPtr<CefBrowser> BroHandler::GetBrowserById(int browser_id) {
  auto it = browser_map_.find(browser_id);
  if (it != browser_map_.end()) {
    return it->second;
  }
  return nullptr;
}

void BroHandler::SetActiveBrowser(int browser_id) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI,
                base::BindOnce(&BroHandler::SetActiveBrowser, this, browser_id));
    return;
  }

  if (browser_id == active_browser_id_) {
    return;
  }

  auto it = browser_map_.find(browser_id);
  if (it != browser_map_.end()) {
    active_browser_id_ = browser_id;
    OnActiveTabChanged(browser_id);

    // Update UI with the new active tab's state
    CefRefPtr<CefBrowser> browser = it->second;
    if (browser) {
      UpdateURL(browser->GetMainFrame()->GetURL().ToString());
      UpdateNavigationState(browser->CanGoBack(), browser->CanGoForward());
    }
  }
}

void BroHandler::CloseBrowser(int browser_id) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefPostTask(TID_UI,
                base::BindOnce(&BroHandler::CloseBrowser, this, browser_id));
    return;
  }

  auto it = browser_map_.find(browser_id);
  if (it != browser_map_.end()) {
    it->second->GetHost()->CloseBrowser(false);
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

  // Only update UI for main frame of the active tab
  if (frame->IsMain() && browser->GetIdentifier() == active_browser_id_) {
    UpdateURL(url.ToString());
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

void BroHandler::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  int browser_id = browser->GetIdentifier();

  // Add to the list and map of existing browsers.
  browser_list_.push_back(browser);
  browser_map_[browser_id] = browser;

  // Set as active browser and notify UI
  active_browser_id_ = browser_id;
  OnTabCreated(browser_id, browser->GetMainFrame()->GetURL().ToString());
}

bool BroHandler::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  // Closing the main window requires special handling.
  if (browser_list_.size() == 1) {
    is_closing_ = true;
  }

  // Allow the close.
  return false;
}

void BroHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  int browser_id = browser->GetIdentifier();

  // Remove from the list and map of existing browsers.
  BrowserList::iterator bit = browser_list_.begin();
  for (; bit != browser_list_.end(); ++bit) {
    if ((*bit)->IsSame(browser)) {
      browser_list_.erase(bit);
      break;
    }
  }
  browser_map_.erase(browser_id);

  // Notify UI about tab closure
  OnTabClosed(browser_id);

  // If we closed the active browser, switch to another one
  if (browser_id == active_browser_id_ && !browser_list_.empty()) {
    active_browser_id_ = browser_list_.front()->GetIdentifier();
    OnActiveTabChanged(active_browser_id_);
  }

  if (browser_list_.empty()) {
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
  if (browser_id == active_browser_id_) {
    UpdateNavigationState(canGoBack, canGoForward);
    SetLoading(isLoading);
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

  // Display a load error message using a data: URI.
  std::stringstream ss;
  ss << "<html><body bgcolor=\"white\">"
        "<h2>Failed to load URL "
     << std::string(failedUrl) << " with error " << std::string(errorText)
     << " (" << errorCode << ").</h2></body></html>";

  frame->LoadURL(GetDataURI(ss.str(), "text/html"));
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
      // Copy link to clipboard
      CefString url = params->GetLinkUrl();
      // Use native clipboard
      return false;  // Let default handler copy
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

  if (browser_list_.empty()) {
    return;
  }

  auto main_browser = browser_list_.front();
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

  if (browser_list_.empty()) {
    return;
  }

  BrowserList::const_iterator it = browser_list_.begin();
  for (; it != browser_list_.end(); ++it) {
    (*it)->GetHost()->CloseBrowser(force_close);
  }
}
