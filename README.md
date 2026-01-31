# Bro Browser

A modern native macOS web browser built with CEF (Chromium Embedded Framework).

## Features

- Native macOS UI with vibrancy effects
- Tab support with loading indicators
- Full navigation (back, forward, refresh)
- Address bar with search support
- Keyboard shortcuts (Cmd+T, Cmd+W, Cmd+L, etc.)
- DevTools support (Cmd+Option+I or F12)
- WebGL and WebGPU support

## Requirements

- macOS 11.0+
- CMake 3.19+
- Xcode Command Line Tools
- CEF Binary Distribution (see Setup)

## Setup

1. Download CEF binary distribution:
   ```bash
   mkdir -p cef-project/third_party/cef
   cd cef-project/third_party/cef
   # Download from https://cef-builds.spotifycdn.com/index.html
   # Extract to: cef_binary_145.0.21+gd7459b1+chromium-145.0.7632.26_macosarm64_beta_minimal
   ```

2. Build:
   ```bash
   mkdir build && cd build
   cmake -G Xcode ..
   cmake --build . --target Bro
   ```

3. Run:
   ```bash
   open build/Debug/Bro.app
   ```

## Architecture

- **bro_app.cc/h** - CEF application callbacks and GPU settings
- **bro_handler.cc/h** - Browser event handling and tab management
- **bro_mac.mm** - Native macOS UI (window, toolbar, tabs)

## License

BSD License (see LICENSE file)
