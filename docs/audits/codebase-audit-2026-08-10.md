# Codebase audit — BroNative

**Date:** 2026-08-10 · **Commit:** `892eaae` (main) · **Mode:** codebase/correctness — adversarial, no loyalty to the current design.

**Method.** Four parallel auditors read the full source (tab strip/window core; toolbar/menus/tab-search/downloads; CEF handler layer; update/build/release pipeline). Their findings were then triaged disprove-first: both High candidates were re-verified in the main session — one survived (H1), one was **refuted at runtime** and demoted (see Considered & Rejected). A Codex cross-model pass independently confirmed F1–F4 below. The prior process audit (2026-08-07) covered CI re-run semantics, shallow-clone versioning, and key-setup ordering — those are not re-litigated here.

---

## Summary

| ID | Sev | Area | Issue | Location | Status |
|----|-----|------|-------|----------|--------|
| H1 | High | Tab strip | Closing the dragged tab mid-drag crashes (`NSRangeException`) | `bro_mac.mm:2833-2846` | CONFIRMED (+Codex) |
| M1 | Med | Tab search | Panel survives Cmd+L / Cmd+[ / Cmd+] — orphaned overlay over live UI | `bro_mac.mm:2570-2646, 4867-4877, 5039` | CONFIRMED (+Codex) |
| M2 | Med | Downloads | Any page can trigger unlimited silent downloads; no consent, no gate | `bro_handler.cc:503-527` | PLAUSIBLE (design) |
| M3 | Med | Updates | First-signed-build gap: no deltas exist; README's "you get a patch" is currently false | workflow + live release | CONFIRMED |
| M4 | Med | Tab strip | Mid-drag close can also feed a dead browser ID to `JoinTabsInSplit`/`SetActiveBrowser` | `bro_mac.mm:2888-2895` | PLAUSIBLE |
| L1 | Low | Overlays | Tab-search panel's outside-click dismissal weaker than downloads popover's (different-window clicks, mouse-button mask) | `bro_mac.mm:2609-2637` vs `4339-4367` | CONFIRMED |
| L2 | Low | Events | `sendEvent:` swallows mouse buttons 3/4 before local monitors run — popover's `OtherMouseDown` outside-click coverage is dead | `bro_mac.mm:4341, 4534-4554` | PLAUSIBLE, Codex-confirmed vs Apple docs |
| L3 | Low | Context menu | "Copy Link" is a silent no-op | `bro_handler.cc:555, 627-632` | CONFIRMED (+Codex) |
| L4 | Low | Popups | `no_javascript_access` left untouched in `OnBeforePopup` — deliberate or forgotten, unreadable | `bro_handler.cc:348-375` | PLAUSIBLE (cosmetic) |
| L5 | Low | Tab strip | Middle-click on a pill mid-close-animation no-ops (model frame already collapsed) | `bro_mac.mm:1450-1459, 2987` | CONFIRMED (cosmetic) |
| L6 | Low | Updates | `KEEP_ARCHIVES=4` retains DMGs the regenerated feed no longer lists (only `MAX_DELTAS+1` are feed-visible) | workflow env | PLAUSIBLE (accepted trade-off?) |
| L7 | Low | Handler | Stale comment: `OnAfterCreated` claims DevTools browsers are tracked — runtime shows they never enter `browser_list_` | `bro_handler.cc:393-395` | CONFIRMED (runtime) |

1 High, 4 Medium, 7 Low.

---

## Map

**Processes.** Main app (`Bro`) + five CEF helpers. All UI in `bro_mac.mm` (5,755 lines); CEF client layer in `bro_handler.cc/h`; updater isolation in `bro_updater.mm`.

**Real execution paths.**
- Tab lifecycle: `CreateBrowser` → `OnAfterCreated` (pushes into `browser_list_`/`browser_map_`, adopts as tab via `OnTabCreated` container match) → close via `CloseBrowser` → `DoClose` (detaches container) → `OnBeforeClose` (erases bookkeeping, picks next active as unfiltered `browser_list_.front()`).
- Tab close from UI is deliberately deferred (`dispatch_async`, `bro_mac.mm:5555`) to avoid re-entering CEF — this deferral is what opens the H1/M4 window: array mutation lands between two `mouseDragged:` events of a still-live drag.
- Popups: `OnBeforePopup` hosts in a pre-created container, adopted synchronously in `OnAfterCreated`. DevTools: `ShowDevTools(..., nullptr client, ...)` — **not** seen by `BroHandler` (verified at runtime; the code comment says otherwise, L7).
- Events: two interception layers — `BroApplication sendEvent:` overrides (Ctrl+Tab, Cmd+←/→, mouse 3/4) and per-feature local `NSEvent` monitors (search panel, downloads popover). Their relative order is what breaks in L2.
- Updates: CI publishes every main build to the single additive `updates` release; `generate_appcast` regenerates the feed each run from current + `MAX_DELTAS` fetched previous DMGs; app polls daily, gated by `UpdaterIsConfigured()`.

**Key invariants (as found, not as documented):** every entry in `browser_list_` currently has a tab view (holds only because DevTools uses a null client); `_tabs` order = strip order = the only tab ordering (handler has none); appcast contents = function of `MAX_DELTAS`, not of what's on the release.

**Expectation gaps.** Expected "Copy Link" to copy — it does nothing (L3). Expected the tab-search panel to behave like a menu (dismiss on any command) — it dismisses only on a handful of coincidental paths (M1). Expected `KEEP_ARCHIVES` to mean "N servable builds" — only `MAX_DELTAS+1` are feed-visible (L6). Expected the README's "you get a patch" — currently every update is a full 158 MB (M3, self-healing).

---

## Findings

### H1 — Closing the dragged tab mid-drag crashes · CONFIRMED (+Codex)
`bro_mac.mm:2833` computes `current = [_tabs indexOfObject:tab]` with no `NSNotFound` check; line 2846 calls `removeObjectAtIndex:current`. `removeTabWithBrowserId:` (2952) never clears `draggingTab_`/`dragging_`.

**Scenario.** Mouse-down on a pill arms a drag (the pill is made active on mouse-down). While the button is held: Cmd+W, `window.close()`, a renderer crash, or a middle-click release on the same pill closes that tab. The close is deferred via `dispatch_async` (5555), so `removeTabWithBrowserId:` runs between two `mouseDragged:` events. Next drag tick: `indexOfObject:` returns `NSNotFound`, and unless the corrupted `delta` math lands in the narrow join branch, `removeObjectAtIndex:NSUIntegerMax` raises `NSRangeException` — a crash of the whole app.

**Direction.** In `dragTab:withEvent:`, abort the drag when `indexOfObject:` returns `NSNotFound`; in `removeTabWithBrowserId:`, clear `draggingTab_`/`dragging_` when the removed tab is the dragged one. Same guard resolves M4.

### M1 — Tab search panel survives commands that should dismiss it · CONFIRMED (+Codex)
No `HideTabSearchPanel()` on `focusAddressBar:` (Cmd+L), `goBack:`/`goForward:` (Cmd+[ / Cmd+]), zoom, split, or pin paths. The panel *does* hide on tab close, active-tab change, resize, and outside click — so it looks fixed in casual testing and orphans only on paths that don't change the active browser.

**Scenario.** ⇧⌘A → Cmd+L. The user is typing a URL in the address field while a stale floating panel sits on top of the toolbar.

**Direction.** A shared "dismiss transient overlays" helper called from `sendEvent:`'s command paths (see T2), rather than adding one more coincidental dismissal site.

### M2 — Downloads are always silent · PLAUSIBLE (design question)
`CanDownload` always returns true; `OnBeforeDownload` always continues with `show_dialog=false`. A hostile page can fill `~/Downloads` unattended.

**Direction.** Open question for the maintainer — if always-allow is intended (Chrome-like default), record that; a cheap middle ground is a per-origin gate after N downloads without a user gesture.

### M3 — First-signed-build delta gap; README claim currently false · CONFIRMED
Root cause traced into Sparkle's `generate_appcast` source: builds 39/42 embed the placeholder `SUPublicEDKey` (they predate `351f544`), the placeholder isn't valid base64 (underscores), so `ArchiveItem.publicEdKey` decodes to nil and both archives are skipped as delta sources *and* left with unsigned enclosures in the feed. Verified against the live appcast: only build 44 carries `sparkle:edSignature`; zero `.delta` assets exist.

**Blast radius is small and shrinking.** Users on 39/42 never started Sparkle (placeholder key → `BroStartUpdater` no-ops), so nobody polls the feed from those builds. The gap self-heals on the next build after 44 — the first pair of real-key builds deltas normally. Residual: README promises "a patch, not another 158 MB," which is false until then and false again after any future first-enablement (e.g. a fork turning signing on).

**Direction.** No code fix. One README line: the first build after enabling signing always ships as a full download. Verify `.delta` assets appear on the run after next.

### M4 — Mid-drag close can reach `JoinTabsInSplit` with a dead ID · PLAUSIBLE
Sibling of H1 through the join branch: `endDragForTab:` can still fire with `joinTargetTab_` set from before the removal, calling `SetActiveBrowser` on a torn-down ID. Same guard as H1 closes it.

### L1 — Overlay dismissal asymmetry · CONFIRMED
The downloads popover hides on clicks in *other windows* and watches `OtherMouseDown`; the tab-search panel explicitly ignores other-window clicks and watches left/right only. Click around a floating DevTools window with the panel open: it stays up. Symptom of T2.

### L2 — Buttons 3/4 never reach local monitors · PLAUSIBLE, Codex-confirmed against Apple docs
`sendEvent:` returns for buttons 3/4 without calling `super`; local monitors are invoked inside `super sendEvent:`, so the popover's `NSEventMaskOtherMouseDown` mask entry is dead for exactly the buttons it exists to catch. Mouse-back with the popover open: page navigates, popover stays. Fix: dismiss overlays in the button-3/4 branch of `sendEvent:` itself (or before the early `return`).

### L3 — "Copy Link" does nothing · CONFIRMED (+Codex)
The menu model is `Clear()`ed and rebuilt with custom IDs; the `MENU_ID_COPY_LINK` case reads the URL into a local and returns false, and CEF has no default action for a custom ID. Write to `NSPasteboard` directly.

### L4 — `no_javascript_access` untouched · PLAUSIBLE (cosmetic)
Almost certainly deliberate (popups share `window.opener` by design here) — one comment line makes it readable as a choice instead of an omission.

### L5 — Middle-click during close animation no-ops · CONFIRMED (cosmetic)
Model frame is already collapsed while the presentation layer still shrinks. Not worth fixing; recorded so it isn't re-found.

### L6 — `KEEP_ARCHIVES` vs feed visibility · PLAUSIBLE
Only `MAX_DELTAS+1` builds appear in the regenerated feed; the other retained DMGs are reachable but unlisted. The workflow comment shows this is a known trade-off — either set `KEEP_ARCHIVES = MAX_DELTAS + 1` or leave as-is deliberately.

### L7 — Stale comment claims DevTools browsers are tracked · CONFIRMED (runtime)
`bro_handler.cc:393-395` says browsers hosted elsewhere (e.g. DevTools) enter the list untabbed. Runtime shows they don't (null client). The comment misled this audit's own handler pass into a false High — fix the comment, or better, make the invariant real (see T1).

---

## Design tensions

**T1 — `browser_list_` ordering is an accidental policy.** "Next active tab after close" = unfiltered `front()`, i.e. creation order of whatever happens to be in the list. It's correct today only because DevTools browsers never enter the list — an invariant that exists by accident (null client) and is documented backwards (L7). Any future non-tab browser (a changed `ShowDevTools` call, a background prerender) reintroduces the blank-window failure we refuted at runtime. Alternative: an explicit tab-order (or MRU) list owned by the handler, with `HasTabView` as a hard filter — MRU would also match user expectations better than creation order.

**T2 — Three transient overlays, three hand-rolled dismissal protocols.** Hover card, tab-search panel, downloads popover each implement their own show/hide + event-monitor logic, and they've already drifted (M1, L1, L2 are all the same disease). One `BroDismissTransientOverlays()` called from the command paths in `sendEvent:` and menu actions collapses the class of bugs.

**T3 — Two event-interception layers with undefined relative order.** `sendEvent:` overrides and per-feature local monitors both intercept; L2 is the first collision. Every new feature picks one arbitrarily. Worth a one-paragraph policy comment in `sendEvent:` naming which layer owns what.

**T4 — The feed is a function of `MAX_DELTAS`, not of the release.** `generate_appcast` regenerates from the fetched subset, so feed contents and release contents drift apart by design (M3, L6). Fine at current scale; revisit if the retention window ever grows.

## Open questions

1. Silent unlimited downloads (M2): intended Chrome-like default, or should there be a gate?
2. "Copy Link" (L3): fix it or drop the menu item?
3. Should the README document that the first build after enabling signing ships full-size (M3)?
4. Sparkle's first-launch consent prompt is deliberately skipped (`SUEnableAutomaticChecks` set explicitly — documented Sparkle behavior). Intended product choice?

## Considered & rejected

- **"Closing the active tab with DevTools open orphans the UI" (was a candidate High)** — REFUTED at runtime: reproduced the exact scenario (DevTools opened on the sole tab, second tab created, first tab closed); the surviving pill was correctly selected. DevTools browsers never enter `browser_list_` because `ShowDevTools` passes a null client. The residue is L7 (stale comment) and T1 (fragile invariant).
- Concurrent drags on two pills — impossible with one pointer; AppKit owns the gesture.
- Hover-card timer retain cycles / stale fires — weak refs throughout; safely no-op.
- KVO/notification observer leaks — zero observers registered in `bro_mac.mm`.
- Favicon fetch race across tab reuse — generation counter discards stale completions.
- 0/1-tab edge cases — lone-tab close short-circuits to `performClose:`; layout helpers clamp.
- Double-click on a pill — no click-count branching; composes correctly.
- DevTools/other windows hijacking `sendEvent:` overrides — all gated on `event.window == g_main_window`.
- Downloads outliving their originating tab — keyed by `download_id`, matches real-browser behavior.
- ⇧⌘A re-invoke race with the chevron — monitor excludes the chevron's hit-rect.
- Cmd+1-9 close-between-validate-and-dispatch — re-validated at dispatch.
- `javascript:`/`data:` URL injection via the address field — scheme whitelist encodes them into searches.
- CEF threading contract violations in the handler — every state-touching path is `CEF_REQUIRE_UI_THREAD` or self-redispatches.
- Popup create/abort race, popup-from-popup, two popups — independent containers, no shared state.
- Renderer-supplied strings — nil-coalesced conversions; the one HTML interpolation is escaped.
- Download path traversal — `lastPathComponent` + unique-name collision handling.
- `SUEnableAutomaticChecks` consent concern — documented Sparkle semantics, not a bug (now open question 4).
- Sparkle tarball hash pin — re-downloaded and re-hashed: matches.
- Updater menu wiring nil-target race — verified ordering and ARC semantics.
- Appcast referencing a just-pruned DMG — impossible by construction (prune window ⊇ feed window).
- Fetch/exclusion logic in the delta step, and the `.delta` upload glob — traced correct; the anomaly was upstream in Sparkle's key decoding (M3).
- Ad-hoc-signing identity warnings inside `generate_appcast`'s delta path — print-only noise, not correctness.
