# WASM Enablement + Stability Fix Round (2026-08-06)

Follow-up to the 2026-01-30 performance design. A multi-agent audit (43 raw
findings, 12 adversarially confirmed) plus live testing drove this round.
Full audit data: `.context/audit-results.json`.

## WebAssembly

Research conclusion for CEF/Chromium 145: every relevant WASM capability
(Liftoff+TurboFan tiering, SIMD, relaxed SIMD, GC, threads, streaming
compilation, compiled-module caching) is **enabled by default** — adding
flags is pure regression risk (this repo already shipped one flag-induced
breakage of form submissions/navigation). What actually improves WASM
performance here:

1. **Persistent cache path** (`~/Library/Application Support/Bro` instead of
   `NSTemporaryDirectory()`): the temp dir was OS-purged, silently discarding
   the HTTP cache and the persisted V8/WASM compiled-code caches every few
   days, forcing full recompiles.
2. **No new command-line switches.** Kept the empirically stable trio
   (`enable-gpu`, `use-angle=metal`, `ignore-gpu-blocklist`), now gated to the
   browser process only.
3. **Bundled benchmark**: `src/mac/wasm-bench.html` (View → WebAssembly
   Benchmark), self-contained hand-assembled WASM with feature probes.
   `#autorun` writes machine-readable results into `document.title`.
   Verified live: `WASMBENCH PASS ratio=4.00 wasm_ms=11.60 simd=1 gc=1
   threads=1`.

WASM threads follow web-standard gating: available on `crossOriginIsolated`
pages (COOP/COEP served by the site). Do NOT enable the global
SharedArrayBuffer flag.

## Confirmed bugs fixed

- **Missing helper app variants (critical).** Chromium launches children from
  exact bundle names; only `Bro Helper.app` existed and `copy_helpers.sh`
  never existed. A/B test proved **no renderer ever spawned → no page ever
  rendered**. CMake now builds all five variants (base, Alerts, GPU, Plugin,
  Renderer) via `CEF_HELPER_APP_SUFFIXES` with per-variant plists
  (`com.bro.browser.helper[.suffix]`, matching `CFBundleExecutable`).
  `VERBATIM` is required on the copy commands (parentheses in bundle names).
- **Use-after-free in UI callbacks (crash, found live).** `dispatch_async`
  blocks captured `const std::string&` parameters *by reference*; the
  referent died before the block ran (`NSInvalidArgumentException: NULL
  cString`). Fixed by converting/copying before dispatch in `UpdateURL`,
  `OnTabTitleChanged`, `OnTabFaviconChanged`, `OpenLinkInNewTab`. This class
  of latent corruption likely caused earlier intermittent instability.
- **Tab close cascaded into app quit.** `DoClose` returning false for a
  child-view browser routes `performClose:` to the shared window →
  `CloseAllBrowsers` → quit. Now: individual closes (tab X, Cmd+W,
  `window.close()`, DevTools protocol) detach the tab's container view and
  return true; the window path is reserved for `closing_all_`/last-browser.
- **Popup handling.** `OnBeforePopup` now parents popups into a new tab
  container (preserves POST bodies, `window.opener`, `window.open()` return
  value — cancel-and-reopen would have regressed OAuth/form flows).
  `OnBeforePopupAborted` cleans up. Non-tab browsers (DevTools) are tracked
  but never touch tab state.
- **Pending-container race.** The `g_pending_browser_container` global handoff
  raced on rapid tab creation; adoption now derives the container from the
  browser's native view (`GetWindowHandle().superview`) synchronously.
- **Remote debugging port 9222 always on.** Now Debug-only; Release opt-in
  via `BRO_REMOTE_DEBUG_PORT`.
- **Multi-window removed.** `newWindow:` hijacked the tab-bar/toolbar globals
  and closing any window quit the app. Single-window model until per-window
  state exists.
- **Smaller fixes**: HTML-escaped error page (URL/error injection), address
  bar scheme allowlist (http/https/file/about; else search) and proper query
  escaping, address bar no longer clobbered while typing, loading state
  synced on tab switch, spinner moved beside the address field, tab overflow
  shrinks tabs instead of overflowing, Dock click deminiaturizes, Cmd+W on
  last tab closes the window, app icon bundled, helper plist placeholders
  fixed (`@ONLY` + helper-specific vars), `-dead_strip` applied per-config.

## Explicitly not done

- Sandbox stays disabled: the *minimal* CEF distribution ships no
  `cef_sandbox` library. Switch to the standard distribution to enable it.
- No `--js-flags`/feature switches (see WASM section).

## Verification recipe

```bash
cmake -G Ninja -B build && cmake --build build
BRO_REMOTE_DEBUG_PORT=9223 ./build/Bro.app/Contents/MacOS/Bro &
curl -s localhost:9223/json/list            # targets + titles
curl -s -X PUT "localhost:9223/json/new?file://$PWD/build/Bro.app/Contents/Resources/wasm-bench.html%23autorun"
# poll /json/list until the bench tab title reads "WASMBENCH PASS ..."
```
