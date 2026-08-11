# Maintainability audit — BroNative

**Date:** 2026-08-11 · **Commit:** `892eaae` (main) · **Mode:** maintainability — should this code exist?

**Method.** Full-source structural read via two parallel analysts (a globals/coupling matrix of `bro_mac.mm`; everything else + dependency currency), synthesized disprove-first. A Codex cross-model pass was attempted and hung at 0 CPU — killed, **failed open** per the audit contract, so no cross-model convergence evidence exists for this report. Team-knowledge reconciliation also failed open (no corpus reachable from this repo). Findings were reconciled against the four open PRs (#15–18) so nothing already fixed in flight is re-reported as new.

---

## Verdict

**NEEDS RESTRUCTURING.** The code *within* each unit is deliberate, commented, and consistent — this is not a messy codebase. But 76% of the app lives in one 5,755-line file holding 14 classes and 25 mutable globals, and the coupling matrix shows that state is what's holding the file together, not cohesion. Three findings from the recent correctness audit (M1/L1/L2 — overlay drift) were symptoms of exactly this structure; the next features will keep paying that tax until the file is split.

## Code-Judo Opportunities

**J1 — Split `bro_mac.mm` along the measured coupling seams, mechanical cuts first.** The full globals/coupling matrix says three extractions move **zero or trivially-externed state** and are pure text moves:

| Cut | Contents | ~Lines | State to move |
|---|---|---|---|
| `bro_favicon.mm` | `BroFaviconLoader` | 100 | none |
| `bro_downloads.mm` | entry model, popover, wiring, bridge callbacks | 700 | 2 externs |
| `bro_toolbar.mm` | `BroAddressField`, `BroToolbar` | 420 | 1 extern |

Two more need one ownership decision each, not a rewrite: `bro_tabsearch.mm` (~580 lines; shares `g_closed_tabs` writes with `OnTabClosed` — give closed-tab history its own tiny module) and `bro_tabstrip.mm` (~2,500 lines; `BroTabBar` currently *orchestrates* split-screen rather than being orchestrated — invert that call direction first). The residual hub (~1,500 lines after all five cuts: window, split, app, bridge callbacks) is where the six blocker globals legitimately converge; `UpdateTabContainerVisibility()` and `UpdateWindowForViewportMode()` become its explicit API. Blocker globals, measured: `g_main_window` (7 subsystems), `g_tab_bar` (5), `g_toolbar` (4), `g_browser_views` (4, bidirectional), `g_split_browser_id` (4, bidirectional), `g_closed_tabs` (3).

**J2 — Delete the SVG path parser; ship 14 PDF assets.** `radix_icons.mm:200-325` hand-parses M/L/H/V/C/S/Z path commands at runtime for 14 icons that are compile-time string constants. Verified: NSImage has no SVG loader on any macOS, but its PDF path supports `setTemplate:` + tint — identical behavior to what the parser produces. Exporting the 14 SVGs to PDF once at authoring time deletes ~250 lines (parser, cache, transform pipeline) with zero runtime difference. 19 live call sites keep working through the same `RadixIconImage` entry point.

**J3 — Extract the two non-CEF jobs out of `BroHandler`; keep the CEF interface surface where it is.** The 7-interface client object is the idiomatic CEF shape (cefsimple-style, including the `PlatformXxx` split) — do not restructure that. What has outgrown it: (a) browser bookkeeping (`browser_list_`/`browser_map_`/`active_browser_id_` + their five accessors, `bro_handler.cc:60-133,667-684`) → a small `BrowserRegistry`, which is also the natural home for the `HasTabView`-filtered next-active policy flagged as design tension T1 in the 2026-08-10 correctness audit; (b) the DevTools CDP description-fetch round-trip (`bro_handler.cc:171-250`) → its own class. Both are self-contained today; the extraction is mechanical.

**J4 — Two proven duplications to collapse.** The outside-click/Esc dismiss monitor is written twice (~40 lines each: downloads popover `4339-4378`, search panel `2609-2637`) — and its two copies already drifted apart badly enough to produce correctness findings L1/L2 last audit. PR #18 unifies the *dismissal calls*; a `BroInstallOutsideDismissMonitor(view, ownerRect, hideBlock)` finishes the job at the *installation* site. The favicon generation-guard idiom is also duplicated verbatim (`BroTabView` 1149-1166, `BroTabSearchRow` 2162-2180).

## Structural Blockers

- `src/bro_mac.mm` — 5,755 lines, **5.7× the 1k-line bar**, 14 classes, 25 mutable file-scope globals, 20-function C bridge, ~40% of it a single class (`BroTabBar` + pills + hover card). Split plan above; no waiver applies.
- Everything else is under 700 lines and cohesive. `bro_handler.cc` (684) is at the bar only because of the two extractable jobs in J3.

## Dependency Audit

- **CEF `151.3.14+chromium-151.0.7922.72` → `151.3.16+chromium-151.0.7922.109`** — same major, same Chromium milestone, two patch builds behind (verified against the live cef-builds index JSON). Routine bump, low urgency, no milestone-level security gap.
- **Sparkle `2.9.5`** — current latest (verified via GitHub API; releases page HTML misleads summarizers, the API is authoritative). No action.
- **CEF version string is hand-duplicated in three places** that must move together: `CMakeLists.txt:19`, workflow `CEF_VERSION` env, README curl URL. A bump touching two of three silently breaks CI caching or the manual-build docs. Single-source it (the bump above is the natural moment).

## Abstraction / Type Cleanup

- `SetLoading` (`bro_mac.mm:5198`) is a **documented no-op still called from two live sites** (`bro_handler.cc:103,475`) and declared in the bridge header — superseded by `OnTabLoadingChanged`. Delete all six lines across three files.
- `MENU_ID_COPY_LINK` dead locals in `bro_handler.cc:627-632` — **already fixed in open PR #17**; recorded here only so it isn't counted twice. No new action.

## Documented / By-Design

- None recorded — team-knowledge corpus unreachable from this repo (pass failed open). Nothing in-repo documents a decision that contradicts a finding above.

## Considered / Rejected

- `BroHandler` as a 7-interface object — the interface surface itself is CEF-idiomatic; only the two non-CEF jobs (J3) leave.
- CMake helper-app `foreach` loop — driven by CEF's own `CEF_HELPER_APP_SUFFIXES`; required Chromium multi-process shape, not duplication.
- `bro_updater.mm` as a thin wrapper — carries real policy (placeholder-key gate); not identity indirection.
- `process_helper_mac.cc`, `bro_app.cc/h` — upstream-template boilerplate, minimal, sound.
- The 20-function C bridge in `bro_handler.h` — verified 1:1 declaration/implementation, CEF-free signatures; the boundary earns its keep.
- Downloads rows vs. search-panel rows unification — similar shape, different models and actions; forcing a shared abstraction would be the "generic framework for one feature" anti-pattern.
- The 39 `static const` layout/timing constants — read-only, travel with their classes, fine.
- Dead-code sweep — no `#if 0`, no commented-out blocks, no unreferenced statics beyond `SetLoading` above.

## Notes

- Suggested sequencing if the split is taken: J4 helpers → mechanical cuts (favicon, downloads, toolbar) → closed-tab-history module + search panel → J3 handler extractions → the tab-strip/split inversion last. Each step compiles and ships independently; nothing requires a flag or a compat layer.
- The four open PRs (#15–18) touch regions affected by the split. Land them first — the cuts are text moves and will absorb them trivially; the reverse order creates conflicts for no benefit.
- Cross-model pass: attempted, Codex hung (0 CPU), killed, failed open. If a second opinion on J1's cut lines is wanted later, rerun it against this report rather than the raw tree.
