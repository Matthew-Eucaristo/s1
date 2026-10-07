# s1 — agent notes

Voice-first macOS agent. Swift 6 / SwiftPM, macOS 26+ (Liquid Glass), no sandbox.
Pre-1.0 with a single main user: **breaking changes are fine, no config migrations**.

## Layout
- `Sources/S1Core` — everything testable: loop, policies, safety gate, voice, config.
- `Sources/s1` — CLI (ArgumentParser). `ModelCommands.swift` = providers/roles commands.
- `Sources/S1App` — SwiftUI app: `AppModel` (agent state, turns), `ModelStore` (providers/roles UI state),
  `ContentView` (sidebar history + conversation), `ModelsSettings`, `SettingsView`, `OnboardingView`, `NotchHUD`.
- Website lives in a separate repo: `../s1-landingpage` (Vite + React, Cloudflare Pages `s1-mac`).

## Model selection (the core design)
- **Provider** = one account/server, one Keychain key (account = provider id). Catalog in
  `S1Core/Config/Providers.swift` (`ProviderCatalog`); connected instances in `config.json → providers`.
- **Role** = `judge | reasoner | transcribe | speak` (one model per job), assigned as `provider/model`
  in `config.json → models`. Unassigned = off (speech roles = on-device Apple).
- **Vision is a capability, not a role:** `Models.seesScreen` sends screenshots to the judge if it reads
  images, else to the reasoner on escalation, else nobody (AX tree only). Catalog `ModelOption.vision`,
  name heuristic `Models.looksVisual`, global switch `config.vision` / `S1_VISION`.
- **S2 plans, S1 executes.** The Reasoner turns new tasks into plain `delegate` steps; the grammar runs
  them. The Judge (`JudgedPolicy`) answers typed questions only: `choice` among `Decision.options` when
  several controls match, a score when the grammar is unsure (< 0.9), and a done-check after UI steps.
  Exact grammar steps are never judged. A Judge that sees captures the screen on demand
  (`JudgedPolicy.capture`), never every step.
- **Distributions, not branches.** An inexact click hands the Judge its top candidates plus "none of
  these"; no match at all sets `Decision.explore`, and `JudgedPolicy.explore` (Decide/Explore.swift)
  narrows coarse-to-fine: which part of the screen (`Screen.regions`: toolbar, tabs, list, page…, a
  beam of ≤ 2 covering 80%), then which control. "None" anywhere → the Reasoner.
- Every UI step's outcome ends with what changed (`ScreenDiff`: "→ new: …", "→ no visible change");
  an AXPress that changed nothing gets one real click on the element's center (not toggles).
  Reasoner actions at (0,0) or confidence < 0.25 are refused and become a question to the user.
- Mac knowledge lives in `S1Core/Policy/MacSkills.swift` (settings pane IDs from
  /System/Library/ExtensionKit, folders, system shortcuts, quick answers); the grammar checks it first
  and the Reasoner prompt includes `MacSkills.guide`. `openURL` only opens settings panes and folders.
- Web search: `WebSearch.kind(endpoint)` picks native model search → OpenAI Responses `web_search` →
  `openrouter:web_search` → none (Reasoner prompt says "no web access, may be out of date"). It runs as
  a visible `.webSearch` step executed by the loop through the Reasoner. Switch: `webSearch` / `S1_WEB`.
- `Models.resolve/endpoint` is the only resolution path; `Brain.policy()/reasoner()` the only place roles
  become a brain — app, `s1 run`, `s1 serve` all use it. Never add per-role endpoint config again.
- Connecting a provider auto-fills only *empty* `judge`/`reasoner`; speech is always opt-in.
- Env: `S1_<ROLE>=provider/model|off`, `S1_<PROVIDER>_KEY`, `S1_VISION=off`, `S1_NUM_CTX`.
- Provider logos: `Sources/S1App/ProviderLogo.swift` (generated, embedded SVG/PNG templates); the site
  uses the same marks in `s1-landingpage/public/logos`.

- Hands-free dictation lives in `Serve` (`Dictation.command` toggles it): while on, utterances go to
  `Config.dictate` (typeText through `CGEventActuator`, so act-time secure-field/terminal checks
  apply), never to a run. ⌃⌥D hold-to-dictate is separate (`AppModel.dictate`, paste).

## Vocabulary (keep it identical in app, CLI, README, site, llms*.txt)
- **Judge = System 1** (fast decision model), **Reasoner = System 2** (LLM). The built-in grammar is
  "the built-in grammar", never its own "System". Step tags: S1 = fast path, S2 = Reasoner.
- Product stance: great defaults, every default configurable; extensible today (custom servers,
  `Policy`/`Reasoner`, skills, Shortcuts, CLI). Plugins are roadmap only; never claim they exist.

## Invariants
- The safety gate runs before every action. The Judge lowers confidence on grammar steps; it raises it
  only by choosing among the grammar's own candidates or finding a control in `explore`, capped at
  `JudgedPolicy.pickedCap` (0.85), so exact grammar hits stay the only near-certain steps.
- Screenshots are optional evidence: perception uses `observe(preferScreenshot:)` so a missing Screen
  Recording grant degrades to the AX tree; only an explicit `.captureScreenshot` action requires it.
- Keys never touch `config.json`. Config writes go through `S1Config.update` (load → mutate → save).
- Keychain: `SecretStore.has` reads attributes only (never prompts); `get` caches per process. Never read a
  secret just to test presence. Data-protection keychain needs a provisioning profile (AMFI kills the
  binary without one), so s1 stays on the login keychain with a stable signing identity.
- UI: glass only on chrome/controls (toolbar, composer, pills, banners); content uses plain fills.
- Accent: `AppModel.accent` (s1 orange `Theme.orange` by default, or the macOS accent via
  Settings → Appearance, UserDefaults `accent`). Use it, never hard-coded colors; `onAccent` for text on it.
- Every user-facing string is localizable; keep `Sources/S1App/id.lproj/Localizable.strings` in sync.
- Paths: always `S1Home.path` (never `NSHomeDirectory() + "/.s1"`); tests get a temp home automatically.
- Typing: `postKeystrokes` sends real layout key codes (`KeyLayout`), unicode only for the rest.
  Text Input Sources (TIS/TSM) calls must run on the main queue (macOS 27 traps otherwise).
- Shared mutable state: `Locked<Value>` / `AtomicFlag` (`S1Core/Util/Sync.swift`, built on
  `Synchronization.Mutex`/`Atomic`). No new NSLock + `nonisolated(unsafe)` pairs; mutate with
  `withLock { }` so read-modify-write is atomic. Long-lived logs go through `JSONL.append` (size-capped).
- AX trees come from one traversal, `AXReader.visit` (focused window first, wrappers skipped,
  closed menus folded, off-window content pruned); refs are its pre-order indices, so snapshots
  and `AXReader.element` must both use it. Prompts list labeled/actionable nodes, not the first N.
- Turn end (`Endpointer`): the noise floor learns only from waiting/quiet frames, the speech peak decays,
  and `TurnEnd.patience` lengthens the pause needed after long speech. Listening turns cap at 45 s.
- Stuck-loop guards apply to model decisions only; grammar steps (`s1:ax`) repeat when the user said so.

## Verify
- SwiftPM targets macOS 26 (`platforms: [.macOS(.v26)]`). The SDK stamped into the binary decides
  whether macOS applies the Liquid Glass design; check with `vtool -show-build` (must say sdk 26+).
- `swift build && swift test`.
- App UI: build a bundle with a separate bundle id (don't clobber the installed S1), back up
  `~/.s1/config.json` first; the app writes it. `scripts/make-app.sh` builds `dist/S1.app`.
- Marketing screenshots: launch with `S1_DEMO=1` (sample turns + history, no hotkeys, 1180x880 window,
  placed on a Retina screen if one exists). Assets must be 2x: on a 1x-only Mac, add a temporary
  HiDPI virtual display (CGVirtualDisplay, DeskPad technique) and capture the window there.
  Update `assets/app.png` and `s1-landingpage/public/shots/app.png` together.
- Release: bump `S1Info.version` + Info.plist, tag `vX.Y.Z`, push, wait for CI's release job, then
  `S1_SIGN_IDENTITY="Apple Development: …" ./scripts/publish-tap.sh X.Y.Z`. The script rebuilds and
  signs locally and replaces CI's ad-hoc zip; an ad-hoc cask build makes TCC drop grants on upgrade.
