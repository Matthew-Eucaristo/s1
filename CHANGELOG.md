# Changelog

All notable changes to s1. Format loosely follows [Keep a Changelog](https://keepachangelog.com/);
this project is pre-1.0 — breaking changes land in minor versions.

## [0.3.0] - 2026-10-06

### Changed: one model per job, vision as a capability (breaking)
- **Four roles:** `judge` (System 1 decision model), `reasoner` (System 2
  LLM), `transcribe`, `speak`. The separate `vision` and `grounder` roles,
  the VLM policy, the click grounder, `s1 ground` and `--policy vlm` are gone.
- **Seeing the screen follows the models.** A judge that reads images (d1,
  Clef) gets screenshots; otherwise a reasoner that reads images gets one with
  each escalation and can click by position; with neither, s1 uses the
  accessibility tree only. The catalog marks every model that sees, names
  outside it are judged by name, and "Let models see the screen" (config
  `vision`, `S1_VISION=off`) turns it off.
- Recommended reasoners that see: Groq Llama 4 Scout, OpenRouter Gemini 2.5
  Flash, Cloudflare Llama 4 Scout, Ollama Qwen3-VL; OpenCode Go lists models live
  and adds DeepSeek V4 Flash Vision.
- **Official provider logos** in Settings (brand tiles), from Lobe Icons and
  typesafe.ai.
- **Screenshot mode** (`S1_DEMO=1`): sample conversation and history for
  README and website shots, hotkeys untouched.

### Changed: providers + roles (breaking, no migration; reconnect your providers once)
- **Providers + roles replace per-role endpoints.** A *provider* is one
  account or server with one Keychain key (`TypeSafe`, `OpenCode Go`,
  `Groq`, `Ollama`, a custom OpenAI-compatible server…); a *role* is what
  s1 uses a model for (`judge`, `reasoner`, `transcribe`, `speak`),
  assigned as `provider/model`. `config.json` now
  carries `providers` + `models`; the old `vlm`/`s2`/`decision`/`grounder`/
  `stt`/`tts`/`brain`/`vlmScreenshot` keys, `providers.json`, per-role
  Keychain items and every config migration are gone.
- **CLI:** `s1 providers`, `s1 connect <provider>` (key → Keychain, live
  check, fills empty judge/reasoner), `s1 disconnect`, `s1 use <role>
  <provider/model|off>`, `s1 models` (catalog + live lists). `s1 key` and
  the old preset `s1 use` are removed; `--vlm-base/--vlm-model/--vlm-screenshot`
  are gone and S2 is on whenever a reasoner is assigned (`--no-s2` opts out).
  Env: `S1_<ROLE>=provider/model|off`, `S1_<PROVIDER>_KEY`.
- **One brain factory.** `Brain` builds S1 (the grammar, judged when a judge
  is assigned) and S2 for the app, `s1 run`,
  `s1 listen` and `s1 serve` alike — the app's Auto/AX picker is gone, and
  the daemon picks up model changes on the next command.
- **App redesign.** Sidebar history of every run (search, run again, show
  evidence) beside the conversation; each command is one turn — your
  request, a live activity card that folds when done, a plain-language
  outcome. Settings → Models is two sections (Brains, Providers) with an
  Add Provider flow that verifies before saving and a detail sheet per
  provider (key, server, roles, models, one-tap Ollama downloads).
  Rebuilt onboarding, notch pill, menu-bar panel; standard About panel
  with credits; Advanced pane for executor, sandbox and config files;
  Indonesian strings updated throughout.
- Run meta.json now records the outcome (`status`, `finished`, `steps`,
  `summary`); usage records use role names.

## [0.2.x] - 2026-10-03 to 2026-10-06

Shipped across the 0.2 pre-releases (see the GitHub releases for each tag).

### Added
- **First-run onboarding** — the app opens a setup wizard once (welcome →
  permissions → Cua Driver → API keys → done); `s1 setup` is the CLI twin
  (`--install-cua`, `--no-cua`, `--non-interactive`). Cua Driver installs
  via CUA's own installer and is the recommended executor; re-run any time
  via the app menu ("Set Up s1 Again…").
- **`s1 doctor`** — validates every file under ~/.s1 (config, providers,
  snippets, convert, skills, memory, tasks) plus keys, cua-driver and the
  sandbox toolchain; `--fix` writes missing defaults and rebuilds the
  memory index. Settings → General shows the same checks inline.
- **Standardized config files** — `~/.s1/providers.json` is now the
  preset catalog behind every Settings menu; `s1 use <id>` applies a
  preset from the CLI. `~/.s1/convert.json` adds user unit/currency
  aliases to the launcher (one hop, validated by doctor).
- **Memory v2** — `~/.s1/memory.md` now follows Cognition's open
  [Agent Memory Repo](https://github.com/AgentMemoryRepo/agentmemoryrepo)
  spec: `remember that <topic>: <fact>` files under `memory/<topic>.md`,
  an auto `[[links]]` index in the main file, `[added:]` date metadata,
  stamp-free dedupe. `forget everything` clears topics too.
- **Context compaction** — turns that slide out of the 200-turn window or
  over the prompt budget are digested into a bounded summary ("N earlier
  turns: goal → outcome …") instead of vanishing; S1/S2 always see the
  freshest work plus a compact recap. All buffers bounded (200 turns,
  120 digest lines, 6k-char window, 1.2k-char digest).
- **Optional shell sandbox** — `"sandbox": "srt"` (or `S1_SANDBOX=srt`,
  Settings → General) wraps shell steps in Anthropic's
  [sandbox-runtime](https://github.com/anthropics/sandbox-runtime) with a
  deny-most policy at `~/.s1/srt-settings.json`. Off by default; fails
  closed when srt isn't installed.
- **Full OSS credits** — Settings → About and ATTRIBUTIONS.md now list
  every runtime tool, spec and design reference with licenses.

### Fixed
- **Listen crash (EXC_BREAKPOINT on `RealtimeMessenger.mServiceQueue`,
  macOS 27)** — the mic resampler answered `.endOfStream` after each tap
  buffer, putting the reused `AVAudioConverter` in its terminal state; every
  later buffer converted to 0 frames and the fallback fed raw mic-format
  audio to SpeechAnalyzer, which traps. Now `.noDataNow`, and an
  unconvertible buffer is dropped, never forwarded.

### Added
- **S1 decision model** — System One API client (`noul`/`choice`/`score`
  + probabilities) for Ollama `/v1/systemone` (nimble, tev1, clef-flash,
  clef), TypeSafe Jev and Cloudflare Clef. Optional judge over model-brain
  steps using bounded current + past context; can only lower confidence.
  `s1 decide` to try one.
- **Connections & API keys** sheet — per-role base/model/presets, test
  button, keys to the Keychain. `s1 key set|rm|ls`. Plaintext config keys
  still read, removed once a Keychain key is saved.
- **`s1 ground <image> <target>`** — debug a grounding model on any
  screenshot: raw reply, parsed `[0,1000]` point, mapped pixel, latency.
  Grounder prompt now restates the `(x, y)` format in the user turn —
  Holo-3.1 0.8b went from prose replies to 3/3 hits within 15/1000.
- **Click grounder role** — optional GUI-grounding model (Holo-3.1 etc.,
  normalized [0,1000] replies; parses `(x,y)`, `click(start_box=…)`,
  `<point>`, `{"x","y"}`, `bbox_2d`) aims click steps. Order: exact AX
  label (no model) → grounder → general VLM. `config.grounder` /
  `S1_GROUNDER_*`; catalog entries + "Use as click grounder" in the app;
  `s1 config` shows and probes it.
- **VLM fast path** — grounding-free intents (open app, type, named keys,
  wait, screenshot, scroll, done) resolve through the grammar with zero
  model calls; only click/set/verify/free-form steps pay for the VLM.
  "buka Notes" with a vision brain is now instant.
- **Live transcript** (volatile partials), **SpeechDetector VAD**, run
  phase status (observing/thinking/reasoning), `keep_alive=30m` +
  JPEG screenshots + 4k ctx for local models, STT locale follows the
  system language.
- **`--policy auto` is the default** — a real decision model when one's
  reachable (probes the VLM endpoint once per command, 3s budget) and
  the deterministic `ax` grammar when it isn't. `s1 run`, `s1 listen`,
  `s1 serve`, and the app's Brain picker all resolve the same way.
- **Storage bound** — `~/.s1/artifacts` auto-prunes to the newest 50 run
  dirs before each run (`S1_KEEP_RUNS` overrides; `0` disables). Only
  run-shaped dirs are touched. New `s1 clean` wipes all run artifacts.
- **Lifecycle hardening** — lid-close mid-run self-heals (hotkey tap
  re-enabled on `tapDisabledByTimeout`, audio engine rebuilt per turn,
  fresh observe on wake); force-kill leaves replayable evidence (JSONL
  is append-per-line, truncated tails are skipped on read); stale
  `run.lock`/`serve.pid` self-heal via live-pid checks; companion feed
  caps at 300 records so serve mode can't grow memory forever.
- **One-click model library** — the app's sidebar lists a curated catalog
  (size, vision vs text, one-line pitch) and every installed ollama model.
  Download is one tap (streams `ollama pull` progress); vision models
  auto-assign to S1, text-only to S2, and any installed model can be
  picked from its ⋯ menu. No ollama? The section says how to get it —
  and the AX brain needs zero downloads regardless. CLI twins:
  `s1 models` (installed + catalog) and `s1 pull <model>` (any model,
  ANSI-free progress).
- **Task library searches `~/.s1/tasks/` too** — `--task name` resolves
  `tasks/<name>.txt` (cwd) first, then `~/.s1/tasks/<name>.txt`, so a
  cask-installed `s1` still has a persistent per-user task library when
  there's no repo checkout. `s1 tasks` lists both directories.

### Fixed
- **Dangling conjunctions stripped from args** — "buka notes lalu" (STT
  hesitation) used to hunt for an app called "notes lalu"; the trailing
  word can't open a new command so it's dropped. Literal-text verbs
  (`type`/`ketik`) keep theirs.
- **Secure-field coverage extended** — `axPress`/`axAction`/`axSetAttribute`
  targeting an `AXSecureTextField` now escalate to a human like `axSetValue`
  already did: an AXConfirm or press can submit a login form, not just inject
  text. Replay applies the same widened check against live trees.
- **`--task` accepts literal paths** — `--task tasks/open-app.txt` (or any
  path containing `/` / ending `.txt`) now resolves as given instead of
  looking for `tasks/tasks/open-app.txt.txt`; bare names still read the
  library.
- **`openApp` accepts `"name"`** — models emit `{"type":"openApp","name":"X"}`
  (seen live in the wild); the codec only read `"app"`/`"text"` and the
  confident step abstained. Both the decoder and the salvage path fixed.
- **"tekan enter" presses Return** — it used to search the AX tree for a
  node named "enter" and abstain on the most common follow-up a user says
  after typing. `tekan`/`press` args that are key names or combos
  ("enter", "spasi", "panah kiri", "cmd s") now emit `keyCombo`; "klik a"
  still clicks the element named "a".
- **Window Run honors `auto` brain** — the picker's Auto choice only
  applied to the companion; the Run button silently used the grammar.
- **Results-drain watchdog** — a `SpeechTranscriber.results` stream that
  never terminates after finalize would wedge a serve turn forever;
  the drain is now bounded (3s) and keeps whatever already landed.
- **Destructive key combos escalate** — ⌘Q / ⌘⌥⎋ in a model's `keyCombo`
  route to a human (unsaved-work / force-quit surface).
- **`s1 serve --install` verifies startup** — it used to report
  "installed" the moment `launchctl kickstart` returned, even when the
  daemon never came up (a `dyld`-wedged binary leaves no trace for 5s).
  It now polls `serve.pid` for ~5s and says "installed + started" only
  when the agent actually claimed it — plus an `s1 status` hint that
  distinguishes "agent installed but not running" from a dead listener.
- **`wake()` re-entrancy guard** — `emit(.listening)` runs handlers
  synchronously; one that toggled back to sleep left the fresh listen
  task grabbing the mic anyway (a zombie engine holding the input). The
  task now re-checks `state == .listening` at run time.
- **One mic lock across every consumer** — `~/.s1/mic.pid`: daemon wake,
  the app's mic button, and foreground `s1 transcribe`/`s1 listen` all
  claim it for their audio session, so a daemon waking mid-capture (or
  two foreground captures) can no longer open two engines on one input.
  `--file` transcription is exempt (no mic).
- **In-process pid claims are idempotent** — `claimPidFile` treated a
  file holding our own pid as "stale" and deleted it, which two parallel
  in-process claims used to race on (each deleting the other's lock).
  An own-pid file now short-circuits as "already owned".
- **"matikan wifi" is a command, not a sleep phrase** — stop phrases that
  double as ordinary verbs (matikan/tidur/istirahat/sleep) must now be the
  whole utterance; "stop dong"-style prefixes still work for stop/berhenti.
- **Untrusted-model crash surface closed** — `scroll` wheel values and
  `wait` durations from model JSON could trap the process on NaN/1e30;
  both are clamped (wheel ±32k px, wait capped at 300s everywhere).
- **`s1 status` shows mid-run "stopping"** — it looked for a daemon state
  called `running`; the daemon publishes `runStart`, so a queued `s1 stop`
  during a run was invisible.
- **`s1 transcribe` shares the mic-ownership rule** — refuses while a
  LISTENING daemon holds the input, same as `s1 listen` (shared
  `throwIfListenerOwnsMic`).
- **`s1 serve --install` plists the real binary** — resolved the brew
  `binary` symlink so a reinstall can't strand the launchd agent.
- **`key <name>` resolves voice aliases** — "key panah kiri" posted the
  raw token "panah" (not a keyCode) and died at the actuator while
  "tekan panah kiri" worked. The key verb now routes through the same
  alias table; unresolvable names abstain to S2 instead of erroring.
- **`set <field>` without a value abstains** — "set username" used to
  write the field's own name into it; now needs "to/dengan/=…" or S2.
- **Conjunction splitting covers commandish verbs** — "buka Notes dan
  tutup" now splits so "tutup" abstains cleanly instead of polluting the
  first intent's argument ("Notes dan tutup"). Typed-text words
  (copy/paste/go/…) stay literal deliberately.
- **AX messaging timeout bounds every observe/act round-trip** — an AX
  query against a wedged or unresponsive app could stall the run
  indefinitely (the kill switch can't interrupt a blocking AX call).
  `AXUIElementSetMessagingTimeout` (1.5s) on each app/system-wide root;
  elements obtained through a timed root inherit the bound, so healthy
  apps are untouched and hung ones prune fast.
- **`auto` probe requires the configured model** — a server answering
  `/models` with 200 but missing the configured model resolved `vlm`
  anyway, then burned every step on "model not found". The probe now
  parses the model list (OpenAI `data[].id` and Ollama `models[].name`)
  and counts the endpoint usable only when our model is in it.
- **`auto` brain upgrades mid-life** — the daemon and the app companion
  probed the local model endpoint once at start; an Ollama that comes up
  later left them pinned to the grammar. A slow re-probe (60s while down)
  upgrades `auto → vlm` when the endpoint answers.

- **`--no-vlm-screenshot` honored under `auto`** — the flag reached only
  the explicit `--policy vlm` branch; the default path read config only.
- **Non-finite coordinates can't reach CGEvent** — salvaged model JSON
  (`"x": 1e999`) decoded to `inf`/`nan`, and a `CGPoint(x: .infinity)`
  posted to `CGEvent` is undefined behaviour. The actuator rejects
  non-finite move/click/drag arguments loudly instead.
- **Word conjunctions can't split typed text** — "ketik aku lalu pergi"
  typed only "aku" because `lalu`/`then`/`terus`/`kemudian`/`lantas`/
  `habis itu`/`setelah itu`/`abis itu`/`lalu`/`trus` split
  unconditionally. Like "dan"/"and", they now split only when the next
  word is a known verb; a non-verb keeps the text intact.
- **Ambiguous `keyCombo` throws** — `["cmd","x","y"]` isn't a chord;
  posting only the last key logs a combo that never ran.
- **`s1 metrics`/`s1 replay` default to the newest run** — bare
  `s1 metrics` used to print a usage error; without an arg it now means
  "the run I just did" (same for `s1 replay`).
- **`s1 capture --out` creates missing parent dirs** — it used to exit 1
  silently when the directory didn't exist; now it creates it and
  reports a real `ValidationError` when the write genuinely can't land.
- **`s1 ax` accepts bundle ids** — `s1 ax com.apple.Notes` resolves the
  running app by `bundleIdentifier` before name matching.
- **Terminal escape injection closed** — action args, outcomes, `s1 ax`
  labels, `s1 status` details and `heard:` transcripts are control-strip-
  sanitized, so model output or a hostile app's AX title can't inject
  ANSI/OSC escape sequences into the CLI feed or serve.log.
- **Unguarded CGEvent posts can't fake success** — drag's mouse-up, the
  focus+click fallbacks (axPress/axSetValue), and scroll wheel events
  used optional chaining: a failed event creation logged "clicked"/
  "drag done"/"scroll" while posting nothing (a missing drag release
  also left the button held). All now throw; interpolated mid-drag
  points stay optional (cosmetic only).
- **`serve-state.json` strips control chars** — a transcript or model
  reply carrying tab/BEL landed raw in the state file's JSON string and
  made `s1 status` unparseable.
- **`s1 run --policy <bad>` error is honest** — it printed
  `Optional("bad")`; now prints the name and lists valid policies.
- **`s1 metrics`/`s1 replay` skip non-run entries** — a stray file or
  folder in the artifacts root used to shadow the newest run (sorted-last
  picked it and failed with "not a run dir"); default selection now
  requires a `steps.jsonl` inside.
- **CLI honors `config.json` locale + speak** — `--locale`/`--language`
  were hardcoded to `id-ID` and `--speak` to off, so the app's GUI
  language/voice settings never reached `s1 listen`/`serve`/`transcribe`/
  `say`. Flags now resolve flag → config → default; `--no-speak`
  overrides a `speak:true` config. `s1 serve --install` forwards the
  resolved values so the plist pins what the installer saw. `s1 config`
  prints all three. Verified: config `{en-US, speak:true}` → plist args
  `--locale en-US --speak`.
### Security
- **Endpoint locality parses the URL host** — `Endpoint.isLocal` used to
  substring-match the whole URL text, so `api.evil.com/?next=localhost`
  or `127.0.0.1.evil.com` counted as "local" and got Ollama-only request
  keys (`think`/`options`) a strict remote 400s on. The host is parsed
  and compared against loopback names/IPs now.
- **keyCombo alias bypasses closed** — `"escape"` slipped past the
  ⌘⌥⎋ Force-Quit deny, and three dangerous chords were unguarded:
  ⌃⌥Space (s1's own wake chord — toggles the agent's listener mid-run),
  ⌃⌘Q (locks the screen — a locked screen stalls the agent blind), and
  ⇧⌘Q (logs the user out entirely). All route to a human now, with
  normalized modifier aliases (`command`/`option`/`alt`/`ctrl`/`spacebar`).
- **Act-time secure-focus re-check** — the loop gates keystrokes against
  the observe-time snapshot, but a password prompt appearing between
  observe and act (model decisions take seconds) would still get typed
  into. `typeText`, `keyCombo`, and the `axSetValue` fallback now re-read
  the live focused element right before posting; a grabbed secure field
  errors the step and the next observe escalates to a human.
- **Terminal-aware typing** — text destined for a terminal's command line
  (Terminal, iTerm2, kitty, alacritty, WezTerm, ghostty, Warp, Hyper,
  tmux…) is scanned with a command-level deny-list: flag-less `rm`,
  `sudo`/`su`, `ssh`, force-push, package removal, `defaults write`,
  `> /dev/` writes, disk/power ops all route to a human. Same scan in
  replay. Caught live: `buka Terminal lalu ketik rm x` typed `rm x` into
  a live shell before this landed.
- **openApp deny-list** — the app NAME is scanned: opening Passwords,
  1Password, or Keychain Access now escalates (credential surface).
  `*password*` matching tightened to catch "Passwords"/"1Password".
- **Secure-field value redaction** — AXSecureTextField values are never
  read (some hosts expose raw text despite the role): not into the
  snapshot, not steps.jsonl, not model prompts.
- **keyCombo secure guard** — Cmd+V paste could reach a password box
  without keystrokes; keyCombo now escalates while a secure field has
  focus (live + replay).
- **Executable URL schemes deny-listed** — `javascript:`, `vbscript:`,
  `data:text/html` typed anywhere escalates (address-bar paste-jacking).
- **Prompt-injection hardening** — model prompts wrap screen content as
  UNTRUSTED DATA; only the goal is an instruction.
- **openApp activation wait** — openApplication returned before the
  window server flipped frontmost, so the next observe could inject
  keystrokes into the wrong app; now waits (bounded ~2s) for real
  keyboard ownership — fixes mistargeted typing and a gate-evaluation
  race.

- **Word-conjunctions respect typed text** — `lalu`/`then`/`terus`/
  `kemudian`/`habis itu`/… used to split unconditionally, so
  `ketik aku lalu pergi` typed only "aku" and abstained on "pergi".
  They now take the same verb-gate as `and`/`dan`: split only when the
  next word is a grammar verb.
### Added
- **Live mic waveform** — `MicLevel` (RMS pushed inside the audio taps, so it
  only exists while listening — zero idle cost) + `LiveWaveform` (TimelineView
  + Canvas, renders only while onscreen): menu-bar label, popover header,
  mic button and notch HUD all show the Siri-style level dance as live proof
  the mic hears you.
- **`s1 serve --install` / `--uninstall`** — always-on launchd agent
  (`com.matthew.s1.serve`): armed at login, `KeepAlive` on non-successful
  exit only (clean `s1 stop` stays authoritative — verified live).
- **`brew services start s1`** — the official Homebrew daemon path (`service do`
  block in the formula): launchd agent at login, crash-only respawn,
  `:interactive` for WindowServer/mic. Requires `brew trust` once (brew's
  gate for service formulas in third-party taps).
- **`s1 serve --install` competing-listener guard** — refuses with a clear
  message while a manual `s1 serve`/app listener holds `~/.s1/serve.pid`
  (the agent would exit non-zero and KeepAlive would respawn-churn forever).

- **Actuator rejects non-finite coordinates** — salvaged model JSON
  (`"x": 1e999`) can carry inf/nan into `.click`/`.drag`/`.moveMouse`;
  a `CGPoint(inf)` posted to `CGEvent` is undefined. The actuator now
  throws before any event is built.
- **Homebrew tap packaging** — `Formula/s1.rb` (binary CLI) + `Casks/s1.rb` (S1.app) + `scripts/publish-tap.sh`: one-command release → GitHub Release → tap publish. Install `brew tap Matthew-Eucaristo/tap && brew install s1` / `--cask s1`; clean removal via `uninstall --cask s1 --zap` (wipes `~/.s1` + Library traces). Both files pass `brew audit --strict` + `brew style`; install/uninstall E2E-verified on a local tap.
- **`s1 ax` capability markers** — `[pressable] [editable] [scrollable] [adjustable] [secure]` in the tree dump, from the new shared `AXSemantics` (single source of truth also used by prompts/AXPolicy).
- **Full pointer + AX verb coverage** — `rightClick`, `doubleClick` (real
  clickState=2 second press), `drag` (interpolated path so drop targets
  see real movement), `axAction` (named AX verbs: AXShowMenu for popups/
  dropdowns, AXIncrement/AXDecrement for sliders and steppers, AXConfirm/
  AXCancel, AXPick, AXRaise/AXOpen), and `axSetAttribute` (AXSelected/
  AXFocused/AXExpanded/AXMain/AXMinimized). Both are whitelisted at the
  actuator and deny-list-scanned; observation marks `[adjustable]` and
  `[pressable]` roles so models pick the right verb. Live-verified:
  double-click selects, right-click opens the context menu.
- **Homebrew tap support** — `Casks/s1.rb` (menu-bar app; `uninstall`
  quits it, `--zap` wipes `~/.s1` + Library traces), binary
  `Formula/s1.rb` (no Xcode needed at install), and
  `scripts/publish-tap.sh` — one command: build artifacts → GitHub
  Release → regenerate tap files → push.
- **App VoiceOver pass** — mic button labeled + ⌘L shortcut, step rows
  speak a single composed line (action, outcome, brain, escalation,
  verify), permission rows announce granted/missing, HUD pill and
  menu-bar glyphs announce state, decorative dots hidden from the
  accessibility tree.
- **Key aliases** — `esc`, `backspace`, `del`, `spacebar`, `pgup`/`pgdn`,
  `leftarrow`/`rightarrow`/`uparrow`/`downarrow`, `fwddelete` all resolve.
- **Notch HUD** — floating status pill under the camera notch while s1
  listens or works (boring.notch-style `NSPanel`, positioned via
  `NSScreen.auxiliaryTopLeftArea/RightArea`); flashes the final status,
  then releases the window — zero steady-state cost. Toggle in the app's
  Companion section / `~/.s1/config.json` `notchHUD`.
- **S1.app** — SwiftUI macOS app: Liquid Glass shell (voice input, live step
  feed, brain/locale/endpoint controls), menu-bar companion, launch-at-login.
- **Always-on companion** — `s1 serve` daemon + `S1.app`: ⇧⇧ double-tap or
  ⌃⌥Space anywhere wakes continuous listening; stop phrases and silence
  auto-sleep; idle uses zero mic/CPU.
- **Voice pipeline** — on-device STT (SpeechAnalyzer → SFSpeechRecognizer
  fallback, 60+ locales incl. id-ID) and TTS (AVSpeechSynthesizer); `s1
  listen`, `s1 transcribe`, `s1 say`.
- **Custom vocabulary** — `~/.s1/config.json` `vocabulary` + `--vocabulary`
  flag feed Apple's contextual strings; installed app names learned
  automatically (100-phrase cap).
- **App Intents** — Siri/Shortcuts/Spotlight can run a goal or toggle
  listening natively.
- **Spotlight resolution** — `open X` resolves apps outside standard dirs
  via `mdfind`, plus fuzzy bigram + containment matching.
- **All-app perception** — every observation carries running apps + window
  titles, not just the frontmost AX tree.
- **Brains** — `AXPolicy` (instant, no model, EN+ID command grammar),
  `VLMPolicy` + `LLMReasoner` (OpenAI-compatible endpoints; default
  `gemma3:4b` on Ollama), confidence-threshold escalation logged to S2.
- **Evidence** — `steps.jsonl` per run (decider, confidence, rationale, raw
  model reply, outcome, verify), screenshots on demand, `s1 metrics`,
  `s1 replay`.
- **Config file** — `~/.s1/config.json` swaps brains/locale/vocabulary
  without a rebuild; precedence flag > env > file > default.
- **Live step feed** — `s1 run`/`demo`/`listen`/`replay` print each step
  as it happens (`[i] decider conf action → outcome`); the serve daemon
  logs the same digest per step.
- **`s1 ax <app|pid>`** — inspect any running app's tree, not just the
  frontmost one.
- **Serve→feed wiring** — companion voice turns now populate the app's step
  feed, status, and run-dir link live (ServeEvent carries each `StepRecord`
  plus the run dir on `runDone`).
- **`scripts/dev-cert.sh`** — one-time setup creating a stable self-signed
  codesigning identity ("S1 Dev Cert"); `make-app.sh` signs with it so TCC
  grants survive rebuilds (ad-hoc signing resets them every rebuild).
  Override with `S1_SIGN_IDENTITY`.
- OSS essentials — MIT license, ATTRIBUTIONS, CONTRIBUTING, SECURITY,
  CI (macOS 26 build+test), release workflow, Homebrew formula template.

### Safety
- Deny-list always routes to a human (credentials, purchases, destructive
  shell incl. fork bomb and rm/dd/diskutil/power-session variants);
  irreversible actions queue for confirmation; kill switch checked every
  step; cascade-failure guard stops AX chains after a failed step.
- **Secure-field guard** — typing while an `AXSecureTextField` has focus, or
  `axSetValue` targeting one, routes to `needsHuman`. Models see `[secure]`
  markers and an explicit never-type rule in the decision format.

### Fixed
- **Menu-bar goal field ate first keystrokes** — the `.window` popover now
  autofocuses the field ~250ms after appearing (typing during the appear
  animation dropped characters).
- EN screenshot phrasings through generic verbs — "take a screenshot",
  "grab the screen", "snap the screen" now resolve to capture in the AX
  grammar (was: unknown-verb abstain → pointless S2 escalation); "take a
  break" still abstains instead of grabbing pixels.
- **Phantom click/typing outcomes** — `CGEvent`/`CGEventSource` creation
  failures (nil events) now throw `S1Error.aborted` instead of logging a
  fake success; `keyCombo` keeps modifier flags on the key-up event so the
  release isn't read as bare keys.
- **Observation failures now land in steps.jsonl** — an `observe()` throw
  writes a terminal "observation failed" record before propagating (was:
  run died with no evidence row).
- **MenuBarExtra run crash** — runs started from the menu-bar quick-goal
  field died instantly ("Block was expected to execute on queue
  com.apple.main-thread"): `observe()`'s AX reads now run on the main
  actor, since HIServices asserts when the first `AXUIElement` contact
  lands on a cooperative-pool thread. Verified end-to-end.
- `serve-state.json` is now valid JSON for any detail text — backslashes
  are escaped and the 120-char truncation can't slice a `\\` pair (was:
  `s1 status` could fail to parse the whole file on a `C:\…`-style detail).
- `RunGoalIntent` (Siri/Shortcuts/Spotlight) refuses with "grant
  Accessibility first" instead of announcing a run that would die.
- `parseWaitSeconds` keeps the sign — "tunggu -5s" clamps to 0 rather
  than becoming a positive 5s wait.
- The VLM hint switch covers `set`/`isi`/`fill` → `axSetValue` guidance.
- App onboarding banner names only the grants actually missing (was:
  always claimed both AX + Screen Recording).
- **Phantom typing closed** — `s1 run`, `s1 demo`, serve runs, and live
  replay now fail fast on missing Accessibility (`requireAccessibility`)
  instead of posting CGEvents that silently drop while the log claims
  "typed N chars". CONTRIBUTING documents the rebuild-invalidation trap
  (ad-hoc builds change cdhash → pane toggles go stale → `tccutil reset`).
- `.wait` steps clamp to 300s (and NaN/negative → 0) — a model emitting
  "wait an hour" can no longer park a run; still kill-switch interruptible.
- App endpoint fields no longer clobber `S1_VLM_*`/`S1_S2_*` env overrides
  — precedence stays flag > env > file > default like the CLI; Serve's S2
  now resolves numCtx+key through `Endpoints.s2()` too.
- `s1 config` warns when config.json exists but is malformed (silent
  default-fallback had made user typos invisible).
- `s1 listen` refuses while the listener daemon actively holds the mic
  (two audio engines grabbing input failed cryptically).
- `RunGoalIntent` refuses on the synchronous `serveIsListening` — the
  mirrored `serveState` lagged a MainActor hop and could admit a Siri-run
  mid-companion-run (same race fixed earlier in `run()`/`listenAndRun()`).
- `s1 stop` semantics unified — SIGTERM only for `s1 serve`; the app
  listener is slept via stop file (window survives, state cleans up).
  Serve `wake()` re-verifies the one-listener lock (a deleted/stolen
  serve.pid can no longer double-listen), and the serve loop sleeps on
  seeing the stop file so `s1 stop` also ends a running utterance turn.
- `wait` intents parse real units — "wait 2 seconds"/"tunggu 500 ms"/
  "wait 1.5 minutes" land at the right duration (was: always 0.5s); the
  LLM codec also accepts a `seconds` field fallback.
- `s1 metrics`/`replay` on a non-run dir report "not a run directory"
  instead of raw Foundation errors.
- Denylist widened: `dd` to `/dev/*` any flag order, `csrutil|bless|fdisk|
  newfs_*|gpt destroy`, `launchctl bootout|disable|unload`; `dd` to a
  regular file is no longer denylisted.
- Daemon no longer starts a second agent while a run is in flight
  (`Config.isBusy` drops the utterance and keeps listening).
- Loop aborts on `Task.isCancelled` and on A-B-A-B action oscillation
  (was: only same-action thrice).
- STT continuation double-resume race fixed with a claimed-once flag —
  a late error can no longer erase a landed transcript.
- S2 decisions now see step history and the decision-engine system
  message (was deciding blind to prior failures).
- `AXReader.element()` re-resolves by identity when the tree shrank
  between snapshot and act (was: nil → step error).
- Screenshot capture skipped entirely when no sink is attached (was:
  captured then discarded).
- `SpeechAnalyzer.prepareToAnalyze` pre-warms the speech model so the
  first utterance isn't cold-slow.
- `config.json` saved with API keys gets 0600 permissions; a malformed
  endpoint URL throws a readable error instead of crashing.
- AX policy: `blocked:` outcomes stop the intent chain, empty `key`
  combos abstain, and the pressable-role set is shared with the LLM
  prompt's `[pressable]` markers.
- `--vlm-screenshot/--no-vlm-screenshot` honors config (default on);
  menu-bar and menu Run buttons trim whitespace like the window's.
- Serve auto-sleeps on consecutive *run* failures too — a broken endpoint
  could spin the daemon forever while the mic kept working (run errors
  now have their own counter, not reset by a successful transcription).
- One listener per machine: `~/.s1/serve.pid` is the lock — a second
  `s1 serve` (or serve inside S1.app + CLI) is refused instead of both
  racing on the same hotkey.
- Replay re-applies the secure-field guards to its live snapshot — a
  re-run can't type into a password box the original run skipped.
- Legacy-mic listen exits as soon as the final transcript lands (was:
  always burned the rest of the turn).
- SpeechAnalyzer mic turns now also end on speech end (0.9s quiet grace
  after the last final segment) instead of always burning `maxSeconds`.
- Cross-process screen ownership: `~/.s1/run.pid` lock means a second
  agent run refuses instead of fighting the live one for the keyboard;
  `s1 status`/`s1 stop` add daemon observability and an off switch.
- Pid-file checks verify executable identity via proc_pidpath — a stale
  pid recycled by an unrelated process can no longer block a run or be
  SIGTERM'd by `s1 stop`.
- AXHelp joins title/description in element labels and ref identity —
  icon-only toolbar buttons are now matchable (and named in `s1 ax`).
- AX attribute reads batch into one IPC call per node
  (`AXUIElementCopyMultipleAttributeValues`) — roughly half the per-step
  observe latency on wide trees.
- Scroll direction convention fixed: dy>0 scrolls content down (browser
  scrollY semantics) and is documented in the decision prompt.
- Process-kill commands (`pkill`/`killall`/`kill -9`) are denylisted —
  the agent can't destroy the session it runs in.
- `serve-state.json` publishes the `running → listening` transition after
  each run (was: stale "running" until the next lifecycle event).
- `steps.jsonl` is append-only — a failed handle can no longer truncate
  the whole evidence trail to one line (was: atomic-write fallback).
- VLM intent cursor counts *consumed* intents, not history length — a
  failed step no longer skips the next goal part (`blocked:` still
  consumes: a deny is final, not transient).
- Pid-file claims (`run.pid`, `serve.pid`) are atomic `O_EXCL` creates —
  two concurrent claims can't both win (was: check-then-create TOCTOU).
- Chat client keeps Ollama-only keys (`think`/`options`/`num_ctx`) on
  local endpoints — strict OpenAI-spec APIs (OpenAI, OpenRouter, Groq)
  400 on unknown params; remote requests use `max_completion_tokens`
  for reasoning models.
- S1.app `run()` refuses politely while a CLI agent owns the screen
  (was: raw busy error surfaced in the status bar).
- `s1 stop` now aborts a bare `s1 run` too — the run watches the shared
  `s1-stop` file by default and clears a stale switch at start.
- `.wait` actions honour the kill switch mid-wait (checked every 0.5s —
  a 60s wait aborts in half a second, not after the full duration);
  same in replay.
- AX attribute re-resolve batches like the tree walk (shared `nodeAttrs`
  — was ~6 IPC calls per node on every `axPress`).
- S1.app config save preserves `vlm/s2` `key`+`numCtx` (was: every save
  wiped stored credentials).
- Quitting S1.app no longer deletes a CLI daemon's `serve.pid` — the
  release is pid-checked (`releasePidFile`).
- `AXValueGetValue` result honoured — a wrong-typed AXValue vendored by
  a foreign app yields nil instead of a zero-size frame.
- `s1 stop` interrupts an in-flight model call — `decide()` is raced
  against the kill file (was: sat out the 300s HTTP timeout), and
  mid-decision aborts report `aborted` instead of a fake S2 escalation.
- Grammar: `and`/`dan` split into a new intent only when followed by a
  verb — "type milk and honey" used to drop "honey" as an unknown intent.
- `AXReader.element()` no longer trusts a stale index when the recorded
  node's identity is gone — fails the action instead of pressing a
  different control (a wrong click is worse than a clean error).
- The serve daemon emits `listening` when a run hands control back —
  the app badge stopped showing "running" (and blocked Listen) until
  the next utterance landed.
- The serve daemon's run loop re-enters `CFRunLoopRun` when its last
  source drops — a dropped event tap used to exit main silently and
  kill the whole listener.
- `wait`/`tunggu` honours unit words — "wait 2 seconds" and "tunggu 2
  detik" used to fall back to 0.5s (the parser only knew `ms`/`s`
  suffixes); `menit`/`minute(s)` and decimal commas work too.
- `s1 replay`/`s1 metrics` on a bad path say "not a run directory"
  instead of Foundation's raw steps.jsonl error.
- Stop semantics unified: the app's Stop (⌘.) couldn't abort
  serve-driven runs (serve watched `s1-serve-stop` while Stop wrote
  `s1-app-stop` — now one file); the serve loop also sleeps on seeing
  its stop file; `s1 stop` no longer SIGTERMs the GUI app — it sends
  the file so the listener sleeps gracefully and the window survives.
- `s1 serve`'s `defer` and SIGTERM/SIGINT handler now release
  `serve.pid` pid-checked (was unconditional `removeItem` — a stolen
  and re-claimed lock file would have been deleted on our exit).
- `.gitignore` no longer drops every PNG — `assets/app.png` (README
  hero, broken on GitHub) and the menubar glyph PNGs (CI builds would
  have silently lost them) are now tracked.
- `.wait` in a dry-run no longer sleeps real seconds — the actuator
  executes nothing, so the recorded 60s wait no longer blocks the
  preview (logged as `[dry-run] wait Ns` in both Loop and Replay).
- Denylist covers `kill <pid>`/`xkill` (default SIGTERM kills too — was:
  only `-9`/`-KILL` variants and pkill/killall matched).
- `openApp` activates explicitly — an app opened in the background never
  came forward, so the next typeText landed in whatever had focus.
- Screenshot capture targets the display holding the main screen, not
  blindly the first enumerated display (multi-monitor).
- Model replies with empty ref/text/keys/app fields now abstain and
  escalate (was: became real actions that failed downstream).
- TTS picks the highest-quality installed voice for the locale
  (premium/enhanced over the base default).
- `make-app.sh` no longer passes `--deep` to codesign — deprecated and
  wrong for a single-binary bundle (it re-signs nested code with the
  app's entitlements).

[Unreleased]: https://github.com/Matthew-Eucaristo/s1/compare/main...HEAD
