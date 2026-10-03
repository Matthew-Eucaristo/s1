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

[Unreleased]: https://github.com/Matthew-Eucaristo/s1/compare/main...HEAD
