# Bring your own brain

Everything that "thinks" in s1 is behind a protocol. You can swap System 1
or System 2 for any model — local or cloud — without touching the loop,
the gate, the logger, or the UI.

## The contracts

```swift
public protocol Policy: Sendable {          // System 1 — fast, per-step
    var name: String { get }
    var wantsScreenshot: Bool { get }        // wants the screenshot attached?
    func decide(observation: Snapshot, goal: String,
                history: [StepRecord]) async throws -> Decision
}

public protocol Reasoner: Sendable {        // System 2 — slow, on escalation
    var name: String { get }
    func decide(observation: Snapshot, goal: String,
                history: [StepRecord], reason: String) async throws -> Decision
}
```

`decide` returns a `Decision`: an optional `Action`, a `confidence` in 0…1,
and a `rationale` (logged verbatim — empty string is fine, silence is not).

Below the run's confidence threshold (the `threshold` argument to
`S1Runner.run`, `confidenceThreshold` on the loop config) the step
escalates: S2 gets the same observation plus S1's rationale, its decision
is logged as `s2:<name>`, and the reason is preserved in `steps.jsonl`.
Below threshold with NO S2 configured, the action is suppressed and
recorded — nothing runs on your screen that a brain wasn't sure about.

## Swapping without code

Models are picked per **role** from connected **providers**: Settings →
Models in the app, or the CLI:

```bash
s1 connect ollama                          # or groq, openrouter, a custom server…
s1 use judge ollama/clef-flash             # System 1's decision model
s1 use reasoner openrouter/anthropic/claude-sonnet-4.5
```

Both write `~/.s1/config.json` (`providers` + `models`); `S1_<ROLE>=provider/model`
overrides a role for one command. Any OpenAI-compatible `/chat/completions`
server works as a custom provider: Ollama, LM Studio, vLLM, MLX, or your own
shim. Seeing the screen follows the models: a judge that reads images gets
screenshots, otherwise a reasoner that reads images gets one per escalation.
`Brain` (Sources/S1Core/Policy/Brain.swift) is the one place roles become a
policy; the app, `s1 run` and `s1 serve` all build their agent there.

## Writing a new brain

1. Conform to `Policy` (or `Reasoner`) in `S1Core`. Be `Sendable` —
   decisions happen on the loop's task.
2. Honor `wantsScreenshot = false` unless you truly need pixels: screenshots
   cost a capture per step and the reason is always logged.
3. Return `nil` action for "I don't know" — the runner handles abstention
   honestly; never fake `.done`.
4. Parse defensively: real models truncate JSON, invent field names, and
   ramble — see `LLMDecisionCodec.salvage` for the tolerated-slop pattern.
5. Keep it deterministic where possible: temperature 0, no chain-of-thought
   tags in the wire format, one action per reply.

Drop a test next to `S1CoreTests` (the file is one flat suite — mimic the
nearest test) and run `swift test`. If your brain needs a new dependency,
say why in the PR — minimal deps is a hard rule.

## Existing implementations to copy from

| Type      | Implementation | Notes                                    |
| --------- | -------------- | ---------------------------------------- |
| `Policy`  | `AXPolicy`     | Zero-model intents — the fast path       |
| `Policy`  | `ScriptedPolicy` | Replay/test plans from JSON            |
| `Policy`  | `DummyPolicy`  | Trivial — the smallest possible example  |
| `Reasoner`| `LLMReasoner`  | OpenAI-compatible chat, escalation style; attaches a screenshot when `vision` |
