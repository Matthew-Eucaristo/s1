# s1 — computer-use harness v0 (System 1)

A voice-first computer operator for macOS, built as a small, auditable system.
**This repo is v0: the harness skeleton only** — the see → decide → act → record
loop, a destructive-action gate, and an audit trail. No voice, no System 1/2
models yet (see [Limits of v0](#limits-of-v0)).

Target machine: the Mac VM on Devin.

```
 perceive ──▶ Observation ──▶ Policy ──▶ ActionGate ──▶ Actuator ──▶ act
                    │        (the brain)   (safety)     (CGEvent)
                    └────────────────┬──────────────────────┘
                                     ▼
                              run/steps.jsonl
                              (audit trail: ts, step, observation, action,
                               gate, result, confidence — one JSON line/step)
```

- **Perceive** — screenshot + window list via ScreenCaptureKit, best-effort AX
  summary (`Sources/s1/Mac/MacPerceiver.swift`). The `Perceiver` protocol keeps
  it mockable off-macOS.
- **Decide** — the `Policy` protocol is the "brain" seam. v0 ships a
  deterministic `DummyPolicy`; a fast local System 1 plugs in here later and
  escalates to System 2 when `confidence` is low.
- **Gate** — every action is classified before it runs: `safe` / `destructive`
  / `unknown`. Destructive actions are rejected unless launched with
  `--allow-destructive`; unknown action kinds always fail closed.
- **Act** — mouse/keyboard via Quartz CGEvent (`Sources/s1/Mac/MacActBackend.swift`).
- **Record** — every step is appended to `run/steps.jsonl` (never overwritten).
- **Preflight** — `s1-cli preflight` checks the macOS TCC permissions the
  harness needs (Screen Recording, Accessibility) and prints the exact fix.

## Layout

| Path | What |
|---|---|
| `Sources/s1/Models.swift` | `Action`, `Observation`, `GateDecision`, `ActionResult`, `StepRecord` |
| `Sources/s1/ActionGate.swift` | whitelist + destructive-action classification (all rules in one place) |
| `Sources/s1/Actuator.swift` | gate application, execution, dry-run; `ActionBackend` protocol |
| `Sources/s1/Perceiver.swift` | `Perceiver` protocol + fallback perceivers |
| `Sources/s1/Policy.swift` | `Policy` protocol + `DummyPolicy` + policy registry |
| `Sources/s1/Loop.swift` | the see → decide → act → record loop |
| `Sources/s1/StepsLog.swift` | JSONL audit-log writer |
| `Sources/s1/Preflight.swift` | preflight model + report formatting (portable) |
| `Sources/s1/CLIMain.swift` | CLI: `preflight` / `dry-run` / `run` |
| `Sources/s1/Platform.swift` | picks macOS vs fallback implementations |
| `Sources/s1/Mac/…` | ScreenCaptureKit perceiver, CGEvent backend, TCC preflight — **macOS only** |
| `Sources/s1cli/main.swift` | thin executable entry point |
| `Tests/s1Tests/…` | tests for the portable core (run anywhere, no macOS needed) |

## Status (2026-10-02)

**Verified on Linux** (Swift 6.0.3, x86_64 — real build + real test run):

- `swift build` — clean build of the library, CLI, and tests.
- `swift test` — **22 XCTest cases, 0 failures**, covering:
  - gate: delete-shortcut and enter/commit rejection, explicit
    `destructive: true` rejection, `--allow-destructive` override, unknown
    action kinds, key action without a key name, safe actions pass;
  - `steps.jsonl`: created, one JSON line per step, schema keys present,
    the gated step recorded as `rejected`;
  - dry-run: performs **zero** backend calls (with a live-run control
    experiment proving the assertion is meaningful) and still applies the gate;
  - CLI parsing/usage, preflight report formatting.
- `swift run s1-cli dry-run --steps 5` — writes `run/steps.jsonl`; the gated
  `key_press enter` step is recorded as `rejected`.

**Not yet verified — needs the Mac VM:**

- The macOS-only code (`Mac/MacPerceiver.swift`, `Mac/MacActBackend.swift`,
  `Mac/MacPreflight.swift`) is `#if`-guarded, so the Linux build **excludes**
  it; it has only been syntax-parsed, never compiled or executed. First
  mission on the VM: build, preflight, dry-run, then a live dummy-policy run.
  Expect small fixes in the ScreenCaptureKit/CGEvent/TCC calls on that first
  pass.

## Setup on the Devin Mac VM

Prerequisites: **macOS 14+** (the ScreenCaptureKit screenshot API needs it) and
either Xcode Command Line Tools or a swift.org toolchain.

**1. Get Swift and the code**

```bash
xcode-select --install    # only if `swift --version` fails
swift --version           # expect Swift 5.9+
gh auth login             # private repo: authenticate first (or use a PAT)
git clone https://github.com/Matthew-Eucaristo/s1.git
cd s1
swift build
```

**2. Check permissions and grant them**

```bash
swift run s1-cli preflight --request
```

`--request` triggers the macOS prompts. Grant both in System Settings (the
`fix:` lines printed by preflight give the exact paths):

- System Settings → Privacy & Security → **Screen Recording** → enable your terminal app
- System Settings → Privacy & Security → **Accessibility** → enable your terminal app

Handy shortcuts to the panes:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

Then **quit and restart the terminal** — TCC changes do not apply to already
running processes — and re-run `preflight` until it prints `result: all good.`

**3. Dry-run, then live**

```bash
swift run s1-cli dry-run --steps 5              # nothing executes; gate still applies
tail -1 run/steps.jsonl                         # inspect the audit line
swift run s1-cli run --policy dummy --steps 5   # first real mouse/keyboard actions
```

## Safety model

- **Whitelist** — only known action kinds can run (`move_mouse`, `click`,
  `double_click`, `right_click`, `type_text`, `key_press`, `hotkey`, `scroll`,
  `wait`). Anything else is `unknown` and always rejected (fail closed).
- **Destructive classification** (all in `Sources/s1/ActionGate.swift`):
  - a policy explicitly marks the action `"destructive": true` (for
    context-dependent risks the gate cannot infer, e.g. clicking a "Buy"
    button or a "Delete" file button);
  - delete/backspace combined with cmd/opt — file-deletion shortcuts;
  - enter/return — commit: may send a message, submit a form, or confirm a
    dialog. Not reversible.
- Destructive actions are **rejected** unless the run is launched with
  `--allow-destructive`. Unknown actions are rejected unconditionally.
- **dry-run still applies the gate** and records every decision — it only
  skips real execution, so a run can be rehearsed and audited before it
  happens.
- Everything that survives the gate is appended to `run/steps.jsonl`; delete
  the run directory to reset.

The gate is deliberately conservative but *rule-based*: it cannot understand
what a click means. v0 therefore requires policies to mark context-dependent
risks explicitly; semantic classification is future work (System 2).

## Run-log format

One JSON object per line in `run/steps.jsonl`:

```json
{"action":{"confidence":0.9,"kind":"move_mouse","x":120,"y":120},
 "confidence":0.9,
 "gate":{"allowed":true,"reason":"ok","risk":"safe"},
 "observation":{"errors":[],"screenshot":"run/shot-….png","ts":"…","windowTitles":[…]},
 "result":{"detail":"moved to (120.0, 120.0)","status":"executed"},
 "step":0,"ts":"2026-10-02T02:13:29.579Z"}
```

- `result.status`: `executed` | `rejected` | `dry_run` | `error`
- `gate.risk`: `safe` | `destructive` | `unknown`
- `observation.errors` records perception failures instead of hiding them.

## Plugging in a model (later)

The whole "brain" contract is one protocol:

```swift
public protocol Policy {
    func next(observation: Observation, step: Int, history: [StepRecord]) -> Action?
}
```

A System 1 policy returns an `Action` with a `confidence`; when confidence is
below threshold the caller escalates to System 2 before the action ever
reaches the gate. To wire one in: add a conforming type in `Sources/s1/`, add
it to `loadPolicy(named:)` in `Policy.swift`, and run
`swift run s1-cli run --policy <name>`. The gate, the log, and the loop stay
unchanged.

## Limits of v0

- No voice input yet (voice-first UX comes later).
- No System 1/System 2 models and no confidence-based escalation — the
  `confidence` field is produced, logged, and ready.
- The gate is rule-based + explicit-flag based, not semantic.
- AX tree is shallow (focused app title only); no OCR/vision.
- Single display, absolute coordinates, no retries/recovery, no
  post-action state verification.

## Development

```bash
swift build
swift test     # runs anywhere — the portable core is fully mocked (no macOS needed)
swift run s1-cli --help
```

License: MIT (see `LICENSE`).
