# Bro Computer

**A simple & minimal web browser.**

Bro Computer strips browsing down to what matters: the page. One quiet row of chrome, no clutter, no noise — just a fast, focused window onto the web that gets out of your way the moment a page loads. Built on [CEF](https://github.com/chromiumembedded/cef).

## Download

Download the latest DMG from the [**latest release**](../../releases/latest) — it is rebuilt automatically on every commit to `main`.

> **First launch:** builds are ad-hoc signed (not notarized), so macOS will warn you.
> Right-click `Bro Computer.app` → **Open** → **Open** the first time. After that it opens normally.

Requires macOS 12.0+ on Apple Silicon.

## Updates

Bro Computer updates itself. It checks once a day while running, and you can ask
it to look now with **Bro Computer → Check for Updates…**. Updates install in
place, so you only download the DMG once.

> The menu item is greyed out until the maintainer sets up signing keys — see
> below. Builds without keys simply never check for updates.

### Enabling updates (maintainer, one time)

Updates are signed, and the signing key is deliberately not in this repo. To
turn them on:

1. Generate a key pair with the copy of Sparkle the build already downloads:

   ```bash
   ./build/_deps/sparkle-src/bin/generate_keys
   ```

   It stores the private key in your login Keychain and prints the public key.

2. Paste the printed public key into `SUPublicEDKey` in `src/mac/Info.plist.in`,
   replacing `REPLACE_WITH_SPARKLE_PUBLIC_KEY`.

3. Export the private key and add it to the repository as a secret named
   `SPARKLE_PRIVATE_KEY` (Settings → Secrets and variables → Actions):

   ```bash
   ./build/_deps/sparkle-src/bin/generate_keys -x sparkle-private-key.txt
   ```

   Delete that file once the secret is saved. Keep the key safe — Sparkle can
   only rotate it with a Developer ID signed build, so losing it means shipped
   apps can no longer be updated.

Until step 3 is done the build still publishes DMGs; it just logs a warning and
skips the update feed.

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
