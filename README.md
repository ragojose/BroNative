# Bro Computer

**A simple & minimal web browser.**

Bro Computer strips browsing down to what matters: the page. One quiet row of chrome, no clutter, no noise — just a fast, focused window onto the web that gets out of your way the moment a page loads. Built on [CEF](https://github.com/chromiumembedded/cef).

## Download

Download the latest DMG from the [**latest release**](../../releases/latest) — it is rebuilt automatically on every commit to `main`.

> **First launch:** builds are ad-hoc signed (not notarized), so macOS will warn you.
> Right-click `Bro Computer.app` → **Open** → **Open** the first time. After that it opens normally.

Requires macOS 12.0+ on Apple Silicon.

### The whole engine

- Chromium 151 with GPU rendering on ANGLE Metal: WebGL 1/2 and WebGPU.
- Full WebAssembly — SIMD, GC, threads, streaming compilation — with a persistent compiled-code cache so hot sites skip recompilation. Verify it yourself: **View → WebAssembly Benchmark** and **View → GPU Benchmark** are built in.
- Chrome's exact zoom ladder (25%–500%) with a zoom HUD, and built-in DevTools (⌥⌘I or F12).

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
open "build/Bro Computer.app"
```

Release mode (`-O3` + LTO) is the default, and the build automatically produces and bundles the five Chromium helper apps (`Bro Computer Helper.app` plus the GPU, Renderer, Plugin, and Alerts variants).

## Debugging notes

- **Remote debugging:** Debug builds listen for DevTools protocol clients on port 9222. Release builds keep it off — opt in with:
  ```bash
  BRO_REMOTE_DEBUG_PORT=9222 "./build/Bro Computer.app/Contents/MacOS/Bro Computer"
  ```
- **Caches:** The browser cache (HTTP + compiled JS/WASM code) lives in `~/Library/Application Support/Bro`.
- **WASM threads** (`SharedArrayBuffer`) follow standard web gating: available on pages served with COOP/COEP headers (`crossOriginIsolated`).
- **No feature flags:** performance comes from stock Chromium defaults (V8 tiering, wasm code caching, BackForwardCache). An earlier round of aggressive command-line switches broke form submissions and navigation, so custom flags are intentionally avoided.
- **Sandbox:** the Chromium sandbox is currently disabled because the *minimal* CEF distribution doesn't ship `cef_sandbox`. Switching to the standard (non-minimal) distribution would enable it.

## Continuous builds

Every push to `main` runs the [Build DMG workflow](.github/workflows/build-dmg.yml): it builds the app on an Apple Silicon runner, ad-hoc signs it, packages a DMG (`Bro-Computer-<version>-<commit>.dmg`), uploads it as a workflow artifact, and refreshes the [latest release](../../releases/latest).


## License

BSD License. UI icons are [Radix Icons](https://www.radix-ui.com/icons) (MIT); the bundled UI typeface is [Geist](https://vercel.com/font) (SIL OFL 1.1).
