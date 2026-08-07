# Process audit — BroNative

**Date:** 2026-08-07
**Branch audited:** `feat/sparkle-ota` (PR #11), which is `main` plus versioned releases and Sparkle OTA. PR #10 (mouse buttons) is not in scope — it changes no process.
**Mode:** process — do the promised journeys compose into complete, walkable paths?

Walks were run in throwaway clones under a scratch dir. Nothing ran against the real repo, releases, or tags. One deviation: the CEF tarball was symlinked from an existing download rather than re-fetched, so step 1 of the README's *download* was verified by HTTP status only, not by a full 250 MB pull.

---

## Resolution status

All nine fixed on this branch, each verified by re-running the walk that found it.

| ID | State | Verified by |
|----|-------|-------------|
| P1 | Fixed | Stubbed both branches: existing release → `upload --clobber`; absent → `create` |
| P2 | Fixed | `cmake_minimum_required` now 3.24; README matches |
| P3 | Fixed | Placeholder+no-secret → warn/exit 0; real key+no-secret → error/exit 1; both reproduced |
| P4 | Fixed | Assert tested at build 31/30/1 against published 30 → pass/pass/fail |
| P5 | Fixed | Deltas via `generate_appcast` on one additive channel release; publish step exercised against a stateful fake release |
| P6 | Fixed | Section moved after the build steps, ordering made explicit |
| P7 | Fixed | `DOWNLOAD_EXTRACT_TIMESTAMP FALSE` |
| P8 | Fixed | Version block isolated and run outside a checkout → warning fires, build 0 |
| P9 | Fixed | `cancel-in-progress` now false on main only |

**P5 was resolved by changing the release layout** (maintainer chose option (a)).
`generate_appcast` emits one `--download-url-prefix` covering full archives and
deltas alike, so they must share a host — per-version releases could not work.
Releases are now a single additive `updates` release holding every DMG, every
delta, and the appcast. Assets are added or replaced, never renamed, so a URL
Sparkle published stays valid. A bounded window of 4 DMGs is retained (enough to
source 2 deltas); older ones are pruned along with their deltas.

Two bugs were caught while building this, both by the harness rather than by
reading: under `set -euo pipefail`, a `grep` that legitimately matched nothing
(empty channel on first run, no stale deltas during pruning) aborted the whole
step. The asset-listing pipeline was duplicated, which is why the same landmine
was written twice; it is now one `list_dmgs` helper.

**Still unverified end-to-end:** delta *generation* itself. The publish step's
orchestration is tested against a stubbed `generate_appcast`; producing and
applying a real delta needs the signing key, which does not exist yet. First real
build after the key lands should be checked for `.delta` assets on the release.

---

## Summary

| ID | Sev | Area | Issue | Location | Status |
|----|-----|------|-------|----------|--------|
| P1 | High | CI release | Re-running a published commit is an unrecoverable dead end | `.github/workflows/build-dmg.yml` "Publish release" | CONFIRMED |
| P2 | High | Build | Declared CMake minimum is below what the build actually requires | `CMakeLists.txt:1`, `README.md:61` | CONFIRMED |
| P3 | High | Update setup | Half-finished key setup points shipped apps at a 404 feed | `README.md:25-53`, `src/mac/Info.plist.in:45` | CONFIRMED |
| P4 | Med | CI release | Shallow clone silently resets the version to 1 and cannot self-detect | `.github/workflows/build-dmg.yml` checkout | CONFIRMED |
| P5 | Med | Update UX | Every update re-downloads the full 158 MB DMG; no deltas | `.github/workflows/build-dmg.yml` "Publish appcast" | CONFIRMED |
| P6 | Med | Docs | Maintainer setup tells you to run a path that does not exist yet | `README.md:25` vs `README.md:55` | CONFIRMED |
| P7 | Low | Build | `DOWNLOAD_EXTRACT_TIMESTAMP TRUE` contradicts CMake's own guidance | `CMakeLists.txt` FetchContent block | CONFIRMED |
| P8 | Low | Build | Building outside a git checkout yields `CFBundleVersion 0` | `CMakeLists.txt` version block | CONFIRMED |
| P9 | Low | CI release | Cancelled run can orphan a release the appcast never references | workflow `concurrency` | PLAUSIBLE |

3 high, 3 medium, 3 low.

---

## Map — release state machine

The record that moves through this system is **a build**. States and the command that advances each:

```
commit on main
  └─ push ──────────────► CI run started            (GitHub, automatic)
        └─ Build ───────► app bundle                (cmake --build)
              └─ Codesign ─► signed bundle          (codesign, ad-hoc)
                    └─ Create DMG ─► local DMG      (hdiutil)
                          ├─ Upload artifact ─► CI artifact (retrievable, 90d)
                          ├─ Publish release ─► immutable release v<short>-<build>
                          └─ Publish appcast ─► feed on the `appcast` release
                                └─ (user's app polls, daily) ─► update installed
```

**Absorbing dead end:** a build that reaches *immutable release* but fails before *appcast* cannot be advanced by any command. Re-running hits P1. The only exit is deleting the release by hand — outside the tooling.

**Unreachable in practice today:** *update installed*. It requires the `SPARKLE_PRIVATE_KEY` secret, which no command in this repo can set (see P3 and Open questions).

---

## Findings

### P1 — Re-running a published commit is an unrecoverable dead end · High · CONFIRMED

**Location:** `.github/workflows/build-dmg.yml`, "Publish release".

`gh release create` has no idempotency flag, and the step has no existence guard, no `|| true`, and no fallback to `gh release edit`.

Verified: `gh release create --help` exposes no `--clobber` or equivalent (the sibling `gh release upload` does — the asymmetry is easy to miss when writing the step).

**Scenario.** "Publish release" succeeds. "Publish appcast" then fails — a flaky `gh release upload`, a token blip, a cancelled run. The maintainer clicks *Re-run failed jobs*. The rebuild recomputes the same commit count, so the tag is the same `v1.0.0-N`; `gh release create` errors with "release already exists" and the job fails again. It will fail on every subsequent re-run. The appcast is left pointing at build N-1 while release N exists and is referenced by nothing. No command in the repo moves this forward.

**Direction.** Make the step idempotent: `gh release view "$tag" >/dev/null 2>&1 && gh release upload "$tag" "$dmg" --clobber || gh release create "$tag" ...`. Same shape already used for the `appcast` release two steps down — P1 is that pattern simply not applied here.

---

### P2 — Declared CMake minimum is below what the build requires · High · CONFIRMED

**Location:** `CMakeLists.txt:1` (`cmake_minimum_required(VERSION 3.21)`), `README.md:61` ("CMake 3.21+").

The Sparkle `FetchContent_Declare` passes `DOWNLOAD_EXTRACT_TIMESTAMP`, which CMake documents as `.. versionadded:: 3.24`.

Verified against CMake's own module docs:

```bash
cmake --help-module ExternalProject | grep -A2 DOWNLOAD_EXTRACT_TIMESTAMP
# ``DOWNLOAD_EXTRACT_TIMESTAMP <bool>``
#   .. versionadded:: 3.24
```

**Scenario.** A contributor on macOS with CMake 3.22 (still shipped by several package managers and older Homebrew pins) follows the README exactly. `cmake -G Ninja -B build` fails on an unknown ExternalProject keyword — before any compilation, with an error that names ExternalProject rather than Sparkle, so the cause is not obvious. The README told them 3.21 was enough.

Not caught locally because this machine runs CMake 4.4.2.

**Direction.** Raise `cmake_minimum_required` to 3.24 and update the README prerequisite to match. This regression arrived with the Sparkle PR; it did not exist on `main`.

---

### P3 — Half-finished key setup points shipped apps at a 404 feed · High · CONFIRMED

**Location:** `README.md:25-53` (setup steps), `src/mac/Info.plist.in:45` (`SUFeedURL`), `.github/workflows/build-dmg.yml` "Publish appcast".

The two setup actions are independent and can be done in either order:
- Step 2 — paste the public key into `SUPublicEDKey` (a commit, done by anyone with write access)
- Step 3 — add `SPARKLE_PRIVATE_KEY` as a repository secret (repo admin only)

`BroStartUpdater` only checks whether the public key is still the placeholder. It has no way to know whether a feed exists.

Verified: with `SPARKLE_PRIVATE_KEY` unset, the appcast step makes **zero** `gh` calls — so the `appcast` release is never created and its URL 404s.

```bash
# reproduced against the extracted step with a stubbed gh
unset SPARKLE_PRIVATE_KEY && sh appcast_expanded.sh
# ::warning::SPARKLE_PRIVATE_KEY is not set — skipping appcast.
# gh calls: 0
```

**Scenario.** Someone does step 2 and opens a PR; the admin hasn't added the secret yet. That build ships to users with a real public key, so `BroStartUpdater` starts Sparkle. Every app polls `.../releases/download/appcast/appcast.xml` daily and gets a 404. Background checks fail silently, but **Check for Updates…** shows the user an update-check error. The state is invisible to whoever did step 2 — CI is green, and the warning is a soft annotation.

**Direction.** Either make the order enforceable (fail the build when `SUPublicEDKey` is real but the secret is absent on a main build — the workflow can already tell), or have `BroStartUpdater` treat a 404 feed as "not configured" and stop scheduling. The first is better: it fails at the point the mistake is made rather than on users' machines.

---

### P4 — Shallow clone silently resets the version to 1 · Medium · CONFIRMED

**Location:** `.github/workflows/build-dmg.yml` checkout step (`fetch-depth: 0`).

Reproduced:

```bash
git clone --depth 1 --branch feat/sparkle-ota file:///path/to/BroNative shallow
cd shallow && git rev-list --count HEAD
# 1
```

`fetch-depth: 0` is the only thing standing between this and a broken release, and nothing asserts it. `actions/checkout` defaults to depth 1, so anyone editing the checkout step, copying the workflow, or adding a second job reintroduces it by omission.

**Scenario.** The version silently becomes 1. That is *lower* than every already-published build, so Sparkle stops offering updates entirely — no error, users just stop receiving them. Simultaneously the tag becomes `v1.0.0-1`, which likely collides with an early release and triggers the P1 dead end. Two failures, neither with an obvious cause.

**Direction.** Assert it in the workflow rather than relying on a comment — fail the build if the computed build number is below the highest existing release tag. That also catches force-push and rebase cases, which `fetch-depth: 0` does not.

---

### P5 — Every update re-downloads the full 158 MB DMG · Medium · CONFIRMED

**Location:** `.github/workflows/build-dmg.yml` "Publish appcast".

The appcast is hand-written and emits a single `<enclosure>` with no `sparkle:deltaFrom` entries. Sparkle therefore downloads the whole DMG for every update. The current release asset is 157,772,529 bytes.

**Scenario.** A one-line fix ships. Every user on a metered or slow connection pulls 158 MB to receive it. At a daily check cadence and frequent commits to main, that is a large recurring transfer for small changes.

Worth stating plainly against the original goal: OTA as built removes the *manual step*, not the *bytes*. Sparkle's `generate_appcast` produces binary deltas (via the bundled `BinaryDelta`) and would cut typical updates to a fraction; the hand-rolled feed cannot.

**Direction.** Move to `generate_appcast` over a directory of retained DMGs if update size matters. That is a real trade — see design tension T1.

---

### P6 — Maintainer setup references a path that does not exist yet · Medium · CONFIRMED

**Location:** `README.md:25` ("Enabling updates") vs `README.md:55` ("Building from source").

The setup step says to run `./build/_deps/sparkle-src/bin/generate_keys`. That path is created by FetchContent during `cmake -G Ninja -B build`, which the README only introduces 30 lines later.

**Scenario.** A maintainer reads top-down, reaches "Enabling updates", runs the command, gets `no such file or directory`, and has no indication that building first is the fix.

**Direction.** Either move the maintainer section below "Building from source", or have it state the prerequisite and download Sparkle standalone. My own addition; it reads fine bottom-up and breaks top-down.

---

### P7 — `DOWNLOAD_EXTRACT_TIMESTAMP TRUE` contradicts CMake's guidance · Low · CONFIRMED

CMake's docs for this option: *"unless the file timestamps are significant to the project in some way, use a false value for this option."* Extracted files keeping archive timestamps can make dependency checking skip work that should rerun. Set it `FALSE`; it silences the CMP0135 warning either way.

---

### P8 — Building outside a git checkout yields version 0 · Low · CONFIRMED

Reproduced: `git rev-list --count HEAD` outside a repo exits non-zero, and the guard falls back to `0`.

Anyone building from a GitHub source zip gets `CFBundleVersion 0`. Harmless for updates (0 is below everything, so updates are offered), but the About panel reports 0, and any future logic comparing build numbers sees a nonsense value.

---

### P9 — Cancelled run can orphan a release · Low · PLAUSIBLE

`concurrency.cancel-in-progress: true` kills an in-flight run when a newer commit lands. If a run is cancelled between "Publish release" and "Publish appcast", release N exists but the feed still points at N-1; the next build publishes N+1 and N is never referenced by anything. Cosmetic on its own, but it also plants the P1 dead end for that tag.

Marked PLAUSIBLE: the window is real and the steps are ordered as described, but I did not reproduce a cancellation landing inside it.

---

## Design tensions

**T1 — Hand-written appcast vs `generate_appcast`.** The hand-rolled feed is legible and has no state: one item, one enclosure, regenerated each build. It also forfeits binary deltas (P5), multi-item version history, and release-note signing, and it re-implements XML that Sparkle already knows how to emit. `generate_appcast` wants a directory of past archives, which means retaining DMGs somewhere it can see them — a real storage and workflow change. Worth taking if update size matters; not worth it if updates are rare.

**T2 — Version as commit count couples release identity to git topology.** It is transparent and needs no stored state, but it is only monotonic while history is append-only. A rebase, force-push, or squash-merge that reduces the commit count moves the version backwards, which silently stops updates (same failure as P4). GitHub's `run_number` is immune but opaque and resets if the workflow is recreated; a committed counter file is monotonic but adds a commit per release.

**T3 — A release per commit.** Every push to main — README typo included — now mints a permanent release and a 158 MB asset. That is the cost of immutable URLs the appcast can point at. The alternative is publishing only on an explicit signal (a tag, a label, a path filter) and letting most commits produce artifact-only builds, at the cost of a more complex trigger.

**T4 — Ad-hoc signing is the ceiling on all of this.** Sparkle will install updates verified by EdDSA, but each installed update remains an app Gatekeeper does not trust. The right-click → Open step survives every update, so the OTA experience stays visibly rough regardless of how good the pipeline is. Notarization (Developer ID, $99/yr) is the only thing that changes it.

---

## Open questions

1. **Who owns the signing key?** The repo is `ragojose/BroNative`; the work is coming from `arzafran`, who has no write access and cannot set secrets. Until that is resolved, the *update installed* state is unreachable no matter what the code does.
2. **Should every commit to main publish a release?** T3 is a deliberate choice I made to get immutable appcast URLs. If the answer is no, the trigger needs rethinking before this merges.
3. **Is 158 MB per update acceptable?** If not, T1 should be settled before OTA ships, not after — the feed format is baked into shipped apps.
4. **Is notarization on the table?** It decides whether OTA is a real feature or a convenience with a permanent rough edge (T4).

---

## Considered & rejected

- **`SUFeedURL` vs the workflow's upload target** — checked character by character; `.../releases/download/appcast/appcast.xml` matches `gh release upload appcast appcast.xml`. No drift.
- **The `appcast` prerelease breaking the README's `/releases/latest` link** — GitHub resolves `/releases/latest` to the newest *non-prerelease*; versioned releases are non-prerelease and the appcast one is. Link still resolves correctly.
- **Missing secret breaking the build** — tested: exits 0, zero `gh` calls, DMG still published. The graceful-skip works as intended.
- **First-run appcast creation** — tested with `gh release view` stubbed to fail: creates the release, then uploads. Correct.
- **Malformed appcast XML** — generated it with stubs and validated with `xmllint --noout`. Well-formed, correct enclosure attributes.
- **Pinned upstream URLs having rotted** — both the CEF tarball and Sparkle 2.9.5 return HTTP 200.
- **Fork PRs leaking the signing secret** — publish steps are gated on `github.ref == 'refs/heads/main'`, and GitHub withholds secrets from fork PRs regardless. No exposure.
