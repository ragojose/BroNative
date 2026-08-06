# Bro Browser

A modern native macOS web browser built with CEF (Chromium Embedded Framework).

## Features

- Native macOS UI with vibrancy effects
- Tab support with loading indicators; popups (`window.open`/`target="_blank"`)
  open as tabs with their navigation intact
- Full navigation (back, forward, refresh)
- Address bar with search support (http/https/file/about schemes only;
  everything else is searched)
- Keyboard shortcuts (Cmd+T, Cmd+W, Cmd+L, etc.)
- DevTools support (Cmd+Option+I or F12)
- WebGL and WebGPU support
- Full WebAssembly support (SIMD, GC, tiering, streaming compilation — all
  Chromium defaults) with persistent compiled-code caching; verify with
  View → WebAssembly Benchmark

## Requirements

- macOS 12.0+ (Apple Silicon)
- CMake 3.21+
- Xcode Command Line Tools (full Xcode not required)
- Ninja (recommended) or Make
- CEF Binary Distribution (see Setup)

## Setup

1. Download the CEF binary distribution (the exact version pinned in
   CMakeLists.txt):
   ```bash
   mkdir -p cef-project/third_party/cef
   cd cef-project/third_party/cef
   curl -L -o cef.tar.bz2 "https://cef-builds.spotifycdn.com/cef_binary_151.3.14%2Bg5d67476%2Bchromium-151.0.7922.72_macosarm64_minimal.tar.bz2"
   tar xjf cef.tar.bz2 && rm cef.tar.bz2
   ```

2. Build (Release with -O3/LTO is the default):
   ```bash
   cmake -G Ninja -B build
   cmake --build build
   ```

3. Run:
   ```bash
   open build/Bro.app
   ```

The build produces all five helper app variants required by Chromium on macOS
(`Bro Helper.app`, plus the `(GPU)`, `(Renderer)`, `(Plugin)`, and `(Alerts)`
variants) and copies them into the bundle automatically.

## Performance notes

- WebAssembly and JS performance comes from Chromium defaults: V8 tiering,
  wasm code caching, and BackForwardCache are all enabled out of the box. No
  feature-forcing command-line switches are used — an earlier round of
  aggressive flags broke form submissions and navigation.
- The browser cache (HTTP + compiled JS/WASM code caches) persists in
  `~/Library/Application Support/Bro`.
- WASM threads (`SharedArrayBuffer`) follow the web-standard gating: they are
  available on pages served with COOP/COEP headers (`crossOriginIsolated`).

## Debugging

- Debug builds listen for DevTools protocol clients on port 9222.
- Release builds keep remote debugging off; opt in by launching with
  `BRO_REMOTE_DEBUG_PORT=9222 open build/Bro.app`.
- The Chromium sandbox is currently disabled: the minimal CEF distribution
  does not ship the `cef_sandbox` library. Switch to the standard (non-minimal)
  CEF distribution to enable it.

## Architecture

- **bro_app.cc/h** - CEF application callbacks and GPU settings
- **bro_handler.cc/h** - Browser event handling, tab lifecycle, popups
- **bro_mac.mm** - Native macOS UI (window, toolbar, tabs) and entry point
- **src/mac/wasm-bench.html** - Bundled self-contained WASM benchmark page

## License

BSD License (see LICENSE file)
