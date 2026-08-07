# Bro Computer

**A simple, minimal browser for distraction-free browsing.**

Bro Computer strips browsing down to what matters: the page. One quiet row of chrome, no clutter, no noise — just a fast, focused window onto the web that gets out of your way the moment a page loads. Built on [CEF](https://github.com/chromiumembedded/cef).

## Download

Download the latest DMG from the [**latest release**](../../releases/latest) — it is rebuilt automatically on every commit to `main`.

> **First launch:** builds are ad-hoc signed (not notarized), so macOS will warn you.
> Right-click `Bro Computer.app` → **Open** → **Open** the first time. After that it opens normally.

Requires macOS 12.0+ on Apple Silicon.

## Features

### Tabs, rethought

- A pill tab strip that lives inside the toolbar — the address bar lives *inside the active tab*, so the chrome stays one row tall no matter what.
- Pinned tabs collapse to favicon-only squares and stay anchored at the front of the strip.
- Drag to reorder; drag one tab *onto* another to enter split screen.
- Hover any tab for an interactive card showing the page title, host, and description, with one-click pin and split actions.
- Popups (`window.open`, `target="_blank"`) open as tabs with navigation, `window.opener`, and form POSTs intact — OAuth and checkout flows just work.
- Reopen a closed tab with ⇧⌘T. Background tabs stop rendering entirely (timers throttled to 1 Hz), so a full tab strip doesn't cost you battery.

### Split screen

Two pages side by side in one window: drag a tab onto another, pick **Window → Split Screen**, or use the hover card. The divider drags from 15% to 85%, both panes render at full speed, and the paired tabs join into a single control in the strip so the layout is always legible.

### A mobile viewport that means it

Toggle any tab into an iPhone-class viewport (390×844, touch events, iOS user agent) — per tab, without affecting the rest. The window itself animates down to phone proportions and back.

### An address bar that behaves

Type a URL and go; type anything else and search. Only `http`, `https`, and `file` URLs are ever navigated — pasted `javascript:` or `data:` input is treated as a search query, never executed.

### Native by craft

- Dark vibrancy glass over your desktop, with a black-glass tint that turns opaque once a page loads.
- Geist typography and Radix iconography, drawn as tintable templates like SF Symbols.
- A single hairline design language for every hover, focus, and selection state.
- Full keyboard access — tabs are focusable and arrow-navigable — and real VoiceOver support with proper tab-group semantics.

### The whole engine

- Chromium 151 with GPU rendering on ANGLE Metal: WebGL 1/2 and WebGPU.
- Full WebAssembly — SIMD, GC, threads, streaming compilation — with a persistent compiled-code cache so hot sites skip recompilation. Verify it yourself: **View → WebAssembly Benchmark** and **View → GPU Benchmark** are built in.
- Chrome's exact zoom ladder (25%–500%) with a zoom HUD, and built-in DevTools (⌥⌘I or F12).

### Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New tab | ⌘N |
| Close tab | ⌘W |
| Reopen closed tab | ⇧⌘T |
| Open location | ⌘L |
| Switch to tab 1–8 / last tab | ⌘1–⌘8 / ⌘9 |
| Cycle tabs | ⌃Tab / ⌃⇧Tab |
| Back / Forward | ⌘[ / ⌘] (or ⌘← / ⌘→) |
| Reload / Hard reload | ⌘R / ⇧⌘R |
| Zoom in / out / reset | ⌘= / ⌘- / ⌘0 |
| Developer Tools | ⌥⌘I or F12 |

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

## Code map

| Path | What it is |
| --- | --- |
| `src/bro_app.cc/h` | CEF application callbacks and GPU settings |
| `src/bro_handler.cc/h` | Browser event handling, tab lifecycle, popups, context menus |
| `src/bro_handler_mac.mm` | macOS-side handler glue |
| `src/bro_mac.mm` | Native macOS UI (window, toolbar, tabs, split screen) and entry point |
| `src/radix_icons.mm/h` | Radix icon set embedded as tintable template images |
| `src/mac/wasm-bench.html` | Bundled self-contained WASM benchmark page |
| `src/mac/gpu-bench.html` | Bundled WebGL/WebGPU verification page |

## License

BSD License. UI icons are [Radix Icons](https://www.radix-ui.com/icons) (MIT); the bundled UI typeface is [Geist](https://vercel.com/font) (SIL OFL 1.1).
