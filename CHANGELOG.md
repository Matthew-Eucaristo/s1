# Changelog

All notable changes to s1. Format loosely follows [Keep a Changelog](https://keepachangelog.com/);
this project is pre-1.0 — breaking changes land in minor versions.

## [Unreleased]

### Added
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

[Unreleased]: https://github.com/Matthew-Eucaristo/s1/compare/main...HEAD
