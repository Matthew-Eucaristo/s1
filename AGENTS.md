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
- `Models.resolve/endpoint` is the only resolution path; `Brain.policy()/reasoner()` the only place roles
  become a brain — app, `s1 run`, `s1 serve` all use it. Never add per-role endpoint config again.
- Connecting a provider auto-fills only *empty* `judge`/`reasoner`; speech is always opt-in.
- Env: `S1_<ROLE>=provider/model|off`, `S1_<PROVIDER>_KEY`, `S1_VISION=off`, `S1_NUM_CTX`.
- Provider logos: `Sources/S1App/ProviderLogo.swift` (generated, embedded SVG/PNG templates); the site
  uses the same marks in `s1-landingpage/public/logos`.

## Vocabulary (keep it identical in app, CLI, README, site, llms*.txt)
- **Judge = System 1** (fast decision model), **Reasoner = System 2** (LLM). The built-in grammar is
  "the built-in grammar", never its own "System". Step tags: S1 = fast path, S2 = Reasoner.
- Product stance: great defaults, every default configurable; extensible today (custom servers,
  `Policy`/`Reasoner`, skills, Shortcuts, CLI). Plugins are roadmap only; never claim they exist.

## Invariants
- The safety gate runs before every action; judges can only lower confidence.
- Keys never touch `config.json`. Config writes go through `S1Config.update` (load → mutate → save).
- Keychain: `SecretStore.has` reads attributes only (never prompts); `get` caches per process. Never read a
  secret just to test presence. Data-protection keychain needs a provisioning profile (AMFI kills the
  binary without one), so s1 stays on the login keychain with a stable signing identity.
- UI: glass only on chrome/controls (toolbar, composer, pills, banners); content uses plain fills.
- Accent: `AppModel.accent` (s1 orange `Theme.orange` by default, or the macOS accent via
  Settings → Appearance, UserDefaults `accent`). Use it, never hard-coded colors; `onAccent` for text on it.
- Every user-facing string is localizable; keep `Sources/S1App/id.lproj/Localizable.strings` in sync.

## Verify
- SwiftPM targets macOS 26 (`platforms: [.macOS(.v26)]`). The SDK stamped into the binary decides
  whether macOS applies the Liquid Glass design; check with `vtool -show-build` (must say sdk 26+).
- `swift build && swift test` (one known-flaky test under load: `serveRunErrorsAutoSleep`).
- App UI: build a bundle with a separate bundle id (don't clobber the installed S1), back up
  `~/.s1/config.json` first; the app writes it. `scripts/make-app.sh` builds `dist/S1.app`.
- Marketing screenshots: launch with `S1_DEMO=1` (sample turns + history, no hotkeys, 1180x880 window,
  placed on a Retina screen if one exists). Assets must be 2x: on a 1x-only Mac, add a temporary
  HiDPI virtual display (CGVirtualDisplay, DeskPad technique) and capture the window there.
  Update `assets/app.png` and `s1-landingpage/public/shots/app.png` together.
- Release: bump `S1Info.version` + Info.plist, tag `vX.Y.Z`, push (CI uploads the zip), then
  `S1_SIGN_IDENTITY="Apple Development: …" ./scripts/publish-tap.sh X.Y.Z`.
