# Bro Browser Performance Optimization Design

## Overview

Optimize Bro Browser across four areas: page load speed, scrolling smoothness, memory usage, and startup time.

## Phase A: Release Build Optimization

**Goal:** Switch from Debug to Release build with full compiler optimizations.

**Changes to CMakeLists.txt:**
1. Add Release build configuration with `-O3` optimization
2. Enable Link-Time Optimization (LTO) for cross-module inlining
3. Strip debug symbols in Release builds
4. Set Release as default build type

**Build command:** `cmake --build build --config Release`

**Expected impact:** 2-5x faster execution, 30-50% smaller binary, lower memory usage.

## Phase B: CEF/Chromium Tuning

**Goal:** Optimize CEF's internal behavior for better memory and page load performance.

**Changes to bro_app.cc (command-line flags):**
1. Enable aggressive disk caching: `--disk-cache-size=104857600` (100MB)
2. Enable back-forward cache: `--enable-features=BackForwardCache`
3. Lazy-load offscreen iframes: `--enable-lazy-image-loading`
4. Enable V8 code caching for faster JS execution

**Changes to bro_mac.mm (CefSettings):**
1. Set `persist_session_cookies = true` for faster repeat visits
2. Configure `background_color` to reduce flash-of-white on load

**Expected impact:** Faster repeat page loads, lower memory with many tabs.

## Phase C: Native UI Optimization

**Goal:** Optimize macOS UI layer for smoother animations and faster startup.

**Changes to bro_mac.mm:**
1. Enable layer-backing on BroTabBar and BroToolbar for GPU compositing
2. Set `layerContentsRedrawPolicy` for efficient redraws
3. Use `CATransaction` to batch animations
4. Defer non-critical UI setup until after first paint

**Expected impact:** 60fps animations, faster perceived startup.

## Implementation Order

1. Phase A (Release builds) - highest impact, lowest risk
2. Phase B (CEF tuning) - medium impact, low risk
3. Phase C (Native UI) - polish, requires testing

## Verification

After each phase:
- Build and run the app
- Test page load on google.com, youtube.com
- Check Activity Monitor for memory usage
- Verify smooth tab switching
