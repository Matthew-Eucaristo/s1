# Contributing to s1

Thanks for helping build a voice-first, open-source macOS agent. This file is
the whole contribution guide — setup, tests, conventions, and the PR flow.

## Setup

Requirements: macOS 15+ (SpeechAnalyzer features need macOS 26/Tahoe), Xcode
with a Swift 6 toolchain. No other dependencies to install — the only package
dependency is `apple/swift-argument-parser`.

```sh
git clone https://github.com/Matthew-Eucaristo/s1.git
cd s1
swift build          # debug build
swift test           # all logic tests — no permissions needed
```

For a real run you need macOS grants on **the app that launches `s1`** (macOS
attributes TCC to the responsible process — usually your terminal):

- System Settings → Privacy & Security → **Accessibility** → enable Terminal
- **Screen & System Audio Recording** → enable Terminal (screenshots only)
- **Speech Recognition** → enable Terminal (STT)

Then verify with:

```sh
./.build/debug/s1 preflight
./.build/debug/s1 demo                 # real 12-step run in TextEdit
```

### TCC gotcha: rebuilds invalidate grants

TCC binds a grant to the binary's code identity. Local builds are ad-hoc
signed, so **every rebuild produces a new cdhash and silently breaks your
existing grants** — the System Settings toggle still shows ON while
`AXIsProcessTrustedWithOptions` returns false. When a freshly rebuilt app
reports ⚠ despite a green toggle:

```sh
tccutil reset Accessibility com.matthew.s1.app   # drop the stale entry
# relaunch, then re-grant in System Settings
```

`s1 run` and the app both **fail fast** on missing Accessibility rather than
typing into the void — an old version logging "typed N chars" that never
landed was a grant that silently stopped applying after a rebuild.

## Testing

`swift test` is the gate — it must stay runnable with **zero macOS
permissions** (unit tests use `NullPerceiver` + `DryRunActuator`, never the
real OS). If your test needs a real screen, it's an integration test — gate it
behind an env var so CI stays clean.

`./scripts/smoke.sh` exercises the whole CLI surface in one go — build,
version, preflight, tasks, config, status, then dry-run demo + a scripted
run (touches nothing). Run it after a fresh clone to sanity-check a machine.

### Republishing the cask artifact (maintainers)

Every change that lands on `main` also ships to the tap:
`./scripts/republish-tap.sh` rebuilds the app, re-zips, commits the
artifact into `releases/v<version>/` in `Matthew-Eucaristo/homebrew-tap`,
pins the cask url to that artifact commit, rewrites sha256, and pushes.
`--no-build` reuses `dist/S1.app`; `--dry-run` prints what it would do.
Users pick up same-version republishes with
`brew update && brew reinstall --cask s1`.

Real-world checks that can't run in CI (they need TCC grants):

```sh
s1 run --task open-app --policy ax            # deterministic AX policy
s1 run --policy vlm --task fill-form          # local VLM (Ollama)
s1 listen --file voice.aiff --locale id-ID    # STT → run → optional TTS
s1 metrics                                    # newest run under ~/.s1/artifacts
```

Every change to the decision/loop path should keep this invariant: a run
folder always contains `meta.json`, `steps.jsonl`, and any screenshots —
evidence over claims.

## Conventions

- **Protocols over implementations.** `Policy` (S1), `Reasoner` (S2),
  `Perceiver`, `Actuator` are the extension points — add a new brain by
  conforming, not by branching inside the loop.
- **No new dependencies without a reason.** Every dependency needs a
  one-line justification in `ATTRIBUTIONS.md`. Prefer native macOS APIs.
- **Evidence over claims.** Log decisions, confidence, who decided, and
  verification results — never print "done" without an artifact.
- **Safety is non-negotiable.** Irreversible actions require explicit
  consent; the hard deny-list (credentials, OTP, card data, purchases,
  unconfirmed messages) is not softened by convenience PRs.
- Small, focused diffs. Match surrounding style. No dead code.
- Comments explain the code as it is — never the bug you fixed or the
  change you made (that goes in the PR description).

## PR flow

1. Fork / branch, `swift build && swift test` green.
2. PR title: imperative, scoped (`fix(vlm): …`, `feat(listen): …`).
3. Body: what changed and *why* — enough for a reviewer who hasn't seen
   the diff. Include `s1 metrics` output or a `steps.jsonl` excerpt for
   behavior changes.
4. CI (`swift build` + `swift test` on macOS) must pass.

## Good first areas

- New `Policy`/`Reasoner` backends (MLX, other OpenAI-compatible endpoints).
- AX coverage: more roles, menu-bar navigation, scroll containers.
- Task-library entries under `tasks/` with real verification.
- Failure-taxonomy additions for the reliability report (`s1 metrics`).
