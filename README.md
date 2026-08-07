# Bro Computer

**A simple & minimal web browser.**

Bro Computer strips browsing down to what matters: the page. One quiet row of chrome, no clutter, no noise — just a fast, focused window onto the web that gets out of your way the moment a page loads. Built on [CEF](https://github.com/chromiumembedded/cef).

## Download

Download the latest DMG from the [**latest release**](../../releases/latest) — it is rebuilt automatically on every commit to `main`.

> **First launch:** builds are ad-hoc signed (not notarized), so macOS will warn you.
> Right-click `Bro Computer.app` → **Open** → **Open** the first time. After that it opens normally.

Requires macOS 12.0+ on Apple Silicon.

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
