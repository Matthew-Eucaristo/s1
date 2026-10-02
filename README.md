# s1

Voice-first macOS agent. A fast local **System 1** (a protocol — swap the implementation) handles most steps; a pluggable **System 2** (LLM, local or cloud) is consulted only when S1 is unsure. Every step is logged with evidence.

**Status:** P0 harness + P1 real-run demo complete. See `PLAN.md` for the roadmap and `docs/` for details.

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
  Policy/    protocol Policy (S1): Dummy · Scripted → AX → VLM (P2)
  Reasoner/  protocol Reasoner (S2): OpenAI-compatible + Anthropic (P2)
  Safety/    Action classes, hard deny-list, kill switch
  Preflight/ TCC checks incl. the relaunch invariant
  Artifacts/ per-run dir: meta.json + steps.jsonl + screens/
  Loop/      see → decide → gate → act → verify → log
Sources/s1/  CLI: preflight · run · demo · capture · ax
```

## Safety

- Action classes: `read` always allowed · `reversible` logged · `irreversible` needs human.
- Hard deny-list: credentials/OTP/card data, purchases, destructive shell — never executed, escalated to a human.
- Kill-switch file checked every step (default path set per run).
- Every run writes `artifacts/<ts>-<goal>/` with `steps.jsonl` — decide-by (`s1:`/`s2:`), confidence, gate verdict, verification result, escalation reason.

## Roadmap

P0 harness ✅ · P1 real run ✅ · P2 S1 AX/VLM policies + S2 escalation · P3 vision on-demand · P4 voice (SpeechAnalyzer STT, AVSpeech TTS) · P5 task library · P6 replay + metrics.

See `PLAN.md` for the research and model choices (Fara1.5-4B, GUI-Owl-1.5-2B, Holo 4, FluidAudio, WhisperKit — all verified actively maintained as of Oct 2026).
