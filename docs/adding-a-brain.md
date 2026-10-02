# Bring your own brain

Everything that "thinks" in s1 is behind a protocol. You can swap System 1
or System 2 for any model — local or cloud — without touching the loop,
the gate, the logger, or the UI.

## The contracts

```swift
public protocol Policy: Sendable {          // System 1 — fast, per-step
    var name: String { get }
    var useScreenshot: Bool { get }          // wants the screenshot attached?
    func decide(goal: String, observation: Snapshot,
                history: [StepRecord]) async throws -> Decision
}

public protocol Reasoner: Sendable {        // System 2 — slow, on escalation
    var name: String { get }
    func reason(prompt: String, observation: Snapshot) async throws -> Decision
}
```

`decide` returns a `Decision`: an optional `Action`, a `confidence` in 0…1,
and a `rationale` (logged verbatim — empty string is fine, silence is not).

Below `Runner.threshold` the step escalates: S2 gets the same observation
plus S1's rationale, its decision is logged as `s2:<name>`, and the reason
is preserved in `steps.jsonl`.

## Swapping without code

`~/.s1/config.json` (or env vars `S1_VLM_*` / `S1_S2_*`, or CLI flags):

```json
{
  "vlm": { "base": "http://localhost:11434/v1", "model": "gemma3:4b" },
  "s2":  { "base": "https://api.openai.com/v1", "model": "gpt-5", "key": "sk-…" }
}
```

Any OpenAI-compatible `/chat/completions` endpoint works — Ollama, LM
Studio, vLLM, MLX server, Groq, OpenAI, or your own shim. Point S1 at a
GUI-tuned model (Fara1.5, GUI-Owl, UI-TARS, Holo) and S2 at a reasoner;
they don't have to be the same vendor, model, or machine.

## Writing a new brain

1. Conform to `Policy` (or `Reasoner`) in `S1Core`. Be `Sendable` —
   decisions happen on the loop's task.
2. Honor `useScreenshot = false` unless you truly need pixels: screenshots
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
| `Policy`  | `VLMPolicy`    | OpenAI-compatible VLM + intent cursor    |
| `Policy`  | `ScriptedPolicy` | Replay/test plans from JSON            |
| `Policy`  | `DummyPolicy`  | Trivial — the smallest possible example  |
| `Reasoner`| `LLMReasoner`  | OpenAI-compatible chat, escalation style |
