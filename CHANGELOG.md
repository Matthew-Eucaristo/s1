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

[Unreleased]: https://github.com/Matthew-Eucaristo/s1/compare/main...HEAD
