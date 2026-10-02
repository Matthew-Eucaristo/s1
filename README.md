# s1

Voice-first macOS agent. A fast local **System 1** (a protocol — swap the implementation) handles most steps; a pluggable **System 2** (LLM, local or cloud) is consulted only when S1 is unsure. Every step is logged with evidence.

**Status:** P0 harness, P1 real run, P2 S1+S2 brains, P4 voice — all verified on real macOS 26. See `PLAN.md` for the roadmap.

- Swift 6, SwiftPM, macOS 15+ (Speech features target macOS 26+), Apple Silicon.
- No sandbox (Accessibility API requires it) — distribute outside the App Store.
- MIT licensed. OSS components used are credited in `ATTRIBUTIONS.md`.

## Try it (3 steps)

```bash
git clone https://github.com/Matthew-Eucaristo/s1.git && cd s1
swift test                      # harness: gate, jsonl, dry-run, loop — no permissions needed
swift run s1 demo --dry-run     # full loop, touches nothing
```

Then the real run (needs both permissions below):

```bash
swift run s1 demo               # opens TextEdit, types, verifies on-screen — logs to artifacts/
```

## Voice

```bash
swift run s1 transcribe --file cmd.aiff --locale en-US   # on-device STT
swift run s1 say "halo" --language id-ID                # on-device TTS
swift run s1 listen --file cmd.aiff                     # voice -> action run
swift run s1 listen                                     # live mic -> action run
```

SpeechAnalyzer (macOS 26) is used when its assets exist; otherwise s1 falls
back to `SFSpeechRecognizer` — still on-device. Dictation must be enabled
(System Settings → Keyboard → Dictation).

## Brains

```bash
# Deterministic S1 — no model, parses "open X, type Y, done" intents
swift run s1 run --policy ax --goal "open TextEdit, wait 2000, type hi, done"

# VLM S1 — any OpenAI-compatible endpoint (Ollama, MLX, LM Studio, cloud)
swift run s1 run --policy vlm --vlm-model gemma3:4b --goal "type hi, done"

# S2 escalation — s1:ax handles known steps; unknown ones go to the LLM
swift run s1 run --policy ax --s2 --goal "open TextEdit, click the document, done"
```

S2 endpoint via env: `S1_S2_BASE` (default `http://localhost:11434/v1`),
`S1_S2_MODEL` (`gemma3:4b`), `S1_S2_KEY`. Every escalation lands in
`steps.jsonl` as `escalation:{to, reason}`.

## Task library & run tooling

```bash
swift run s1 run --task open-app --policy ax        # goals live in tasks/*.txt
swift run s1 metrics artifacts/<run-dir>            # decisions/escalations/errors/verify stats
swift run s1 replay artifacts/<run-dir> --dry-run   # re-execute a recorded run
```

## Permissions (macOS TCC)

`s1 preflight` reports what's missing and prints exact instructions.

| Permission | Why |
|---|---|
| Accessibility | CGEvent input + reading the AX tree (the main perception path) |
| Screen & System Audio Recording | on-demand screenshots (ScreenCaptureKit) — **relaunch s1 after first grant** |
| Microphone | voice input only (P4) |

When running via `swift run`, grant the permission to the produced binary
(`.build/debug/s1`) or to your terminal, then relaunch.

## Layout

```
Sources/S1Core/
  Perceive/  CGWindowList + AXUIElement tree + ScreenCaptureKit (on-demand)
  Act/       CGEvent mouse/keyboard + AX actions; DryRunActuator
  Policy/    protocol Policy (S1): Dummy · Scripted · AX (deterministic) · VLM
  Reasoner/  protocol Reasoner (S2): OpenAI-compatible chat endpoints
  Voice/     SpeechAnalyzer + SFSpeechRecognizer STT · AVSpeech TTS
  Safety/    Action classes, hard deny-list, kill switch
  Preflight/ TCC checks incl. the relaunch invariant
  Artifacts/ per-run dir: meta.json + steps.jsonl + screens/
  Loop/      see → decide → gate → act → verify → log
Sources/s1/  CLI: preflight · run · demo · capture · ax · transcribe · say · listen
```

## Safety

- Action classes: `read` always allowed · `reversible` logged · `irreversible` needs human.
- Hard deny-list: credentials/OTP/card data, purchases, destructive shell — never executed, escalated to a human.
- Kill-switch file checked every step (default path set per run).
- Stuck-loop guard: the same action three times in a row aborts the run (`stuckLoop`).
- Every run writes `artifacts/<ts>-<goal>/` with `steps.jsonl` — decided-by (`s1:`/`s2:`), confidence, gate verdict, verification result, escalation reason, and `modelReply` (the raw model output).

## How S1 thinks

- **AX policy** (`--policy ax`, default): zero model, parses `open X, type Y, done` intents and executes deterministically — the baseline every smarter S1 must beat.
- **VLM policy** (`--policy vlm`): goal → deterministic intent cursor (shared grammar with AX policy) → the model grounds ONE intent per step. Small local models decide actions; they don't track whole plans. Truncated/malformed JSON is salvaged field-by-field before a strict-JSON retry.
- **S2** (`--s2`): any OpenAI-compatible endpoint; called only below the confidence threshold, with the reason logged.
- Defaults on this project: `gemma3:4b` via Ollama for VLM and S2 (benchmarked on an arm64 VM: correct JSON ≈1min/step on CPU; much faster on a real Mac). Set `S1_VLM_MODEL` / `S1_S2_MODEL` to swap.

### Permissions caveat

macOS attributes TCC grants to the *responsible* process: run `s1` from Terminal and **Terminal** needs the Accessibility / Screen Recording / Speech Recognition grants — not just the `s1` binary. `s1 preflight` reports what the current host is missing.

## Roadmap

P0 harness ✅ · P1 real run ✅ · P2 S1 AX/VLM + S2 escalation ✅ · P3 vision on-demand ✅ · P4 voice ✅ · P5 task library ✅ · P6 replay + metrics ✅.

See `PLAN.md` for the research and model choices (Fara1.5-4B, GUI-Owl-1.5-2B, Holo 4, FluidAudio, WhisperKit — all verified actively maintained as of Oct 2026).
