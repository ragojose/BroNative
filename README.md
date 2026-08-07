# Bro Browser

A fast, modern, native macOS web browser built on [CEF](https://github.com/chromiumembedded/cef) (Chromium Embedded Framework) — real Chromium under the hood, with a lightweight native Cocoa UI on top.

## Download

Grab the latest DMG from the [**latest release**](../../releases/latest) — it's rebuilt automatically on every commit to `main`.

> **First launch:** builds are ad-hoc signed (not notarized), so macOS will warn you.
> Right-click `Bro.app` → **Open** → **Open** the first time. After that it opens normally.

Requires macOS 12.0+ on Apple Silicon.

## Features

- 🪟 Native macOS UI with vibrancy effects
- 🗂 Tabs with loading indicators — popups (`window.open` / `target="_blank"`) open as tabs with navigation intact
- 🧭 Full navigation: back, forward, refresh, and an address bar that searches anything that isn't a URL
- ⌨️ Familiar keyboard shortcuts (⌘T, ⌘W, ⌘L, …)
- 🛠 DevTools built in (⌘⌥I or F12)
- 🎮 WebGL and WebGPU support
- ⚡️ Full WebAssembly support (SIMD, GC, tiering, streaming compilation — all Chromium defaults) with persistent compiled-code caching — try it yourself via **View → WebAssembly Benchmark**

## Building from source

### Prerequisites

- macOS 12.0+ on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install` — full Xcode not needed)
- CMake 3.21+ and Ninja (`brew install cmake ninja`)

### 1. Get CEF

Download the exact CEF binary distribution pinned in `CMakeLists.txt` (one-time, ~250 MB):

```bash
mkdir -p cef-project/third_party/cef
cd cef-project/third_party/cef
curl -L -o cef.tar.bz2 "https://cef-builds.spotifycdn.com/cef_binary_151.3.14%2Bg5d67476%2Bchromium-151.0.7922.72_macosarm64_minimal.tar.bz2"
tar xjf cef.tar.bz2 && rm cef.tar.bz2
cd ../../..
```

### 2. Build and run

```bash
cmake -G Ninja -B build
cmake --build build
open build/Bro.app
```

That's it. Release mode (`-O3` + LTO) is the default, and the build automatically produces and bundles the five Chromium helper apps (`Bro Helper.app` plus the GPU, Renderer, Plugin, and Alerts variants).

## Tips & debugging

- **Remote debugging:** Debug builds listen for DevTools protocol clients on port 9222. Release builds keep it off — opt in with:
  ```bash
  BRO_REMOTE_DEBUG_PORT=9222 open build/Bro.app
  ```
- **Caches:** The browser cache (HTTP + compiled JS/WASM code) lives in `~/Library/Application Support/Bro`.
- **WASM threads** (`SharedArrayBuffer`) follow standard web gating: available on pages served with COOP/COEP headers (`crossOriginIsolated`).
- **No feature flags:** performance comes from stock Chromium defaults (V8 tiering, wasm code caching, BackForwardCache). An earlier round of aggressive command-line switches broke form submissions and navigation, so we don't do that anymore.
- **Sandbox:** the Chromium sandbox is currently disabled because the *minimal* CEF distribution doesn't ship `cef_sandbox`. Switching to the standard (non-minimal) distribution would enable it.

## Continuous builds

Every push to `main` runs the [Build DMG workflow](.github/workflows/build-dmg.yml): it builds the app on an Apple Silicon runner, ad-hoc signs it, packages a DMG, uploads it as a workflow artifact, and refreshes the [latest release](../../releases/latest).

## Code map

| Path | What it is |
| --- | --- |
| `src/bro_app.cc/h` | CEF application callbacks and GPU settings |
| `src/bro_handler.cc/h` | Browser event handling, tab lifecycle, popups |
| `src/bro_mac.mm` | Native macOS UI (window, toolbar, tabs) and entry point |
| `src/mac/wasm-bench.html` | Bundled self-contained WASM benchmark page |

## License

BSD License
