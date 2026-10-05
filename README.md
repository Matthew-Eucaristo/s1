<p align="center"><img src="assets/logo/s1.svg" width="128" alt="s1 logo"></p>

# s1

[![CI](https://github.com/Matthew-Eucaristo/s1/actions/workflows/swift.yml/badge.svg)](https://github.com/Matthew-Eucaristo/s1/actions/workflows/swift.yml)
[![Release](https://img.shields.io/github/v/release/Matthew-Eucaristo/s1?include_prereleases&label=release&color=orange)](https://github.com/Matthew-Eucaristo/s1/releases)
[![Beta](https://img.shields.io/badge/status-public%20beta-orange)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

Voice-first macOS agent. A fast local **System 1** (a protocol — swap the implementation) handles most steps; a pluggable **System 2** (LLM, local or cloud) is consulted only when S1 is unsure. Every step is logged with evidence.

> **Public beta (v0.x)** — works, tested, and still sharpening. Read [`SECURITY.md`](SECURITY.md) before letting it drive a real machine.

**Status:** P0 harness, P1 real run, P2 S1+S2 brains, P4 voice, **macOS app (Liquid Glass)**, **always-on companion (global hotkey → continuous listening)** — all verified on real macOS 26. See `PLAN.md` for the roadmap.

<p align="center"><img src="assets/app.png" width="720" alt="S1.app — a real run: 'buka Notes' opened Notes and logged both steps"></p>

- Swift 6, SwiftPM, macOS 15+ (Speech features target macOS 26+), Apple Silicon.
- No sandbox (Accessibility API requires it) — distribute outside the App Store.
- MIT licensed. OSS components used are credited in `ATTRIBUTIONS.md`.

## Install

```bash
# Homebrew — the recommended way (one package carries GUI + CLI):
brew tap Matthew-Eucaristo/tap
brew trust Matthew-Eucaristo/tap   # required once on Homebrew ≥4.4 (third-party cask taps)
brew install --cask s1      # the S1 menu-bar app; `s1` CLI lands on PATH too

s1 preflight                # shows which macOS permissions are missing
s1 serve --install          # optional: always-on listener (launchd, armed at login)
```

Or grab the signed zip straight from
[**Releases**](https://github.com/Matthew-Eucaristo/s1/releases/latest)
(`S1-*-app.zip` — drag `S1.app` into /Applications; the `s1` CLI is inside
`Contents/Resources/`).

**First launch (beta, ad-hoc signed):** macOS 26 blocks unnotarized apps
with "Apple could not verify S1 is free of malware" and no Open button.
Either way works once:
- **System Settings → Privacy & Security** → scroll down → "S1 was blocked"
  → **Open Anyway**;
- or remove the quarantine flag: `xattr -d com.apple.quarantine /Applications/S1.app`
- or reinstall with `brew install --cask s1 --no-quarantine`.

Proper notarization (Developer ID + `xcrun notarytool`) is on the roadmap
for the 1.0 release.

Remove it cleanly any time (one cask carries everything — `--zap` is the full wipe):

```bash
s1 serve --uninstall              # first, if you installed the always-on agent
brew uninstall --cask s1            # quits the app + removes /Applications/S1.app
brew uninstall --cask s1 --zap      # + wipes ~/.s1 state and Library traces
```

<details><summary>From source instead</summary>

```bash
git clone https://github.com/Matthew-Eucaristo/s1.git && cd s1
./scripts/install-local.sh            # or: swift build -c release && cp .build/release/s1 /usr/local/bin/

s1 preflight                          # shows which macOS permissions are missing

# The app:
./scripts/dev-cert.sh                 # once: stable dev cert → TCC grants survive rebuilds
./scripts/make-app.sh                 # builds dist/S1.app (universal)
open dist/S1.app                      # or copy it to /Applications
```

> Without `dev-cert.sh`, make-app.sh falls back to ad-hoc signing — which
> resets your TCC grants (Accessibility, Screen Recording, Input Monitoring)
> on every rebuild. dev-cert.sh is a one-time setup that makes grants stick.

</details>

## Try it (3 steps)

```bash
git clone https://github.com/Matthew-Eucaristo/s1.git && cd s1
swift test                      # harness: gate, jsonl, dry-run, loop — no permissions needed
swift run s1 demo --dry-run     # full loop, touches nothing
```

Then the real run (needs both permissions below):

```bash
swift run s1 demo               # opens TextEdit, types, verifies on-screen — logs to ~/.s1/artifacts/
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

**Custom vocabulary** — s1 always feeds the recognizer contextual strings:
installed app names are learned automatically (say "open Linear" and it
lands). Add your own jargon to `~/.s1/config.json`:

```json
{ "vocabulary": ["s1", "Warp", "JIRA"] }
```

or per command: `--vocabulary "Warp,JIRA"`. Apple's limit is 100 phrases —
your words rank first, app names fill the rest.

**Turn detection + barge-in** — while a run or the spoken reply is in
flight, an energy-only monitor (voice-processing AEC keeps s1's own TTS
from tripping it) listens for sustained speech: talk over the agent and it
aborts at the next step, then the mic reopens for the new command. Turn
ending is Apple `SpeechDetector` + an RMS endpointer; the detector's
sensitivity and the endpointer's margins are configurable:

```json
{ "voiceInterrupt": true, "vad": "auto", "vadSensitivity": "medium" }
```

`"vad": "energy"` runs the deterministic RMS endpointer alone (no detector
module); sensitivity `low` tolerates thinking pauses, `high` cuts the turn
fast. Env overrides: `S1_VOICE_INTERRUPT`, `S1_VAD`, `S1_VAD_SENSITIVITY`.
All three are also in Settings → Listening.

## Always-on companion

```bash
swift run s1 serve              # daemon: arms the global hotkey, then idles (zero mic/CPU)
swift run s1 serve --wake       # start listening immediately (for SSH/headless use)
s1 serve --install              # launchd agent: armed at login, respawns after a crash
s1 serve --uninstall            # removes the agent (logs at ~/.s1/serve.log)
```

Press **⇧⇧** (double-tap either Shift) or **⌃⌥Space** anywhere on the Mac:
s1 toggles between `idle` and `listening`. While listening it loops
**hear → run the goal → speak → hear** until you say a stop phrase
(`stop`/`berhenti`/`tidur`/`istirahat`/`sleep`…) or press the hotkey again; it auto-sleeps
after `--idle-turns` silent turns or repeated STT errors — and after
repeated run failures (a dead endpoint can't spin hot). Idle uses no mic
and no model — flat battery. One listener per machine: `~/.s1/serve.pid`
is the lock, so `s1 serve` alongside S1.app is refused instead of
double-triggering on the same hotkey. Typing fast capital letters does
NOT fire ⇧⇧ — any key between the taps resets the gesture.

```bash
s1 status      # daemon state, run in progress?, ~/.s1 disk footprint
s1 stop        # abort any in-flight run + stop the listener
               # (SIGTERM for `s1 serve`; the app only sleeps — window survives)
s1 clean       # wipe all run artifacts + truncate serve.log (runs auto-prune to newest 50)
```

`~/.s1/run.pid` marks screen ownership — a second agent run refuses while
one is live (two agents typing at once is the failure this prevents).
Stale pid files self-heal: liveness + executable identity are checked,
so a recycled pid never blocks you — and `s1 stop` can't kill the wrong
process. `~/.s1/serve-state.json` is the daemon's last state (for scripts).

The S1 app is the same daemon with a menu-bar face (`MenuBarExtra`): the
waveform icon shows idle/listening/running, toggles listening, and offers
**Launch at login** (`SMAppService.mainApp`). The window stays available
for one-shot commands.

While s1 listens or works, a status pill drops from the camera-notch
strip — the Dynamic-Island idiom, done the only way third-party Mac apps
can (a floating `NSPanel` tucked between `NSScreen.auxiliaryTopLeftArea`
and `auxiliaryTopRightArea`; there's no public notch API). It carries a
mini stop button and, per Apple's efficiency model, the window only
exists while s1 is doing something — idle releases it entirely. Disable
it in the app's Companion section or `~/.s1/config.json` (`"notchHUD": false`).

Measured on this Mac (M-series, macOS 26): armed + idle with nothing on
screen = **0.0% CPU, ~140 MB RSS**; the CLI agent = **0.0% CPU, ~19 MB**
mid-run — there are no timers or polling loops anywhere, every state
change is event-driven (CGEvent tap, serve events, `@Observable`).

Perception includes a whole-Mac view: every observation lists running apps
+ window titles (`AppState`), and `open X` resolves apps outside the
standard dirs via Spotlight (`mdfind kMDItemKind == 'Application'`).

## Siri, Shortcuts, Spotlight

The app ships **App Intents** — the same actions the UI performs are
system-discoverable:

- "Ask s1 to open TextEdit" / "Run … in s1" → `RunGoalIntent` (brings the
  window forward, goal prefilled and executed)
- "Wake s1" / "Toggle s1 listening" → `ToggleListeningIntent` (same switch
  as the hotkey)

Both appear in Shortcuts.app for automation, and Siri picks up the phrases
automatically.

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

### Swapping brains — the easy way

Everything lives in `~/.s1/config.json` — no rebuild, no code:

```json
{
  "vlm": { "base": "http://localhost:11434/v1", "model": "gemma3:4b" },
  "s2":  { "base": "https://api.openai.com/v1", "model": "gpt-5", "key": "sk-…" },
  "locale": "id-ID", "speak": true
}
```

Precedence: **CLI flag > env var > config file > built-in default**. Any
OpenAI-compatible `/chat/completions` endpoint works for both brains —
Ollama, LM Studio, vLLM, MLX, Groq, OpenAI. `s1 config` prints what's
resolved and where to edit; the app writes the same file, so GUI settings
apply to the CLI too. To write a custom brain (a `Policy` or `Reasoner`
conformance — swap internals, not the loop), see `docs/adding-a-brain.md`.

### Three roles, any models

| Role | What it does | Good picks on a 16 GB Mac |
| --- | --- | --- |
| **S1 brain** (`vlm`) | one decision per step; grammar-only steps (open/type/keys/wait) skip it entirely | `qwen3-vl:8b`, `qwen3-vl:4b`, `gemma3:4b` |
| **Click grounder** (optional) | GUI-trained model that turns "click Save" + screenshot into a point — asked only for click steps the AX tree can't resolve | `ahmadwaqar/holo-3.1:0.8b` / `:4b` (Holo-3.1, Apache 2.0) — any model answering in normalized `[0,1000]` coords works (MAI-UI, GUI-Owl, Qwen3-VL) |
| **S2 reasoner** | escalation on low confidence | local `qwen3:8b`, or any cloud OpenAI-compatible API |

Click order: exact AX label match (no model) → grounder → general VLM.
Grounder config: `"grounder": {"model": "ahmadwaqar/holo-3.1:0.8b"}` in
`~/.s1/config.json` (base defaults to the VLM's server) or
`S1_GROUNDER_MODEL`/`S1_GROUNDER_BASE`/`S1_GROUNDER_KEY`.
Try a grounder on any screenshot before wiring it in:
`s1 ground shot.png "Save button" --model ahmadwaqar/holo-3.1:0.8b`
(prints the raw reply, the parsed `[0,1000]` point and the pixel it maps to).

S2 is plain OpenAI `/chat/completions`, so subscriptions with a compatible
endpoint drop in by URL + key — e.g. OpenCode Go
(`"s2": {"base": "https://opencode.ai/zen/go/v1", "model": "glm-5.3"}` +
`s1 key set s2`), OpenRouter (any model, incl. Claude), Groq, OpenAI,
Google Gemini (`…/v1beta/openai`), xAI Grok, DeepSeek. Settings → Models
lists every provider with a pill per role it covers (S1 judge, S2, STT,
TTS) — one Connect click wires them all, one pasted key covers the whole
card, and configured connections re-test on page-open and on every model
change. The app exposes two S1 brains only — **Auto** (grammar + judge,
the default) and **AX** (grammar alone, zero model calls); hard steps
always escalate to S2, it isn't a toggle. The VLM brain + click grounder
remain CLI/config paths (`--policy vlm`, `"grounder"`); future S1 models
are expected to see the screen themselves rather than need a separate
grounder UI.

### S1 decision model (optional judge)

A *decision model* is not a chatbot: it answers typed questions —
`noul` (yes/no → probability), `choice` (option + full distribution),
`score` (ordered levels) — over a JSON `state`, with no free-form text to
parse. s1 speaks the **System One API** (`POST …/v1/systemone`), which one
client covers for every provider:

| Provider | Base | Models | Notes |
| --- | --- | --- | --- |
| Ollama ≥ 0.35 (local) | `http://localhost:11434` | `nimble` 9B, `tev1` 4B, `tev1:0.8b`, `clef-flash` 9B, `clef` 27B | open weights, no key |
| TypeSafe Jev (hosted) | `https://api.typesafe.ai` | `jev-latest` | closed, text-only, key |
| Cloudflare Workers AI | `https://api.cloudflare.com/client/v4/accounts/<id>/ai/run/@cf/cloudflare/clef` | `clef`, `clef-flash` | Apache-2.0 weights, key |

When set, it judges every step a *model* brain (VLM) proposes: "does this
move toward the goal, given the screen and the run so far?" and "is this
repeating a step that already failed?". The state it sees is bounded —
goal, frontmost app, window titles, ≤40 control labels (never field
values), the last 8 steps with outcomes. A low score lowers the step's
confidence, which routes it to S2 (or stops). It never raises confidence,
never overrides the safety gate, and skips the exact AX grammar. Judge down
→ the step proceeds as before.

```bash
ollama pull tev1:0.8b
s1 decide "Goal: open TextEdit. Frontmost: Finder." "Which brain?" --options deterministic,vision,planner --model tev1:0.8b
```

Config: `"decision": {"base": "http://localhost:11434", "model": "nimble"}`
or `S1_DECISION_MODEL`/`S1_DECISION_BASE`/`S1_DECISION_KEY`, or the app's
**Connections & API keys…** sheet. Small models are poorly calibrated on
our steps (tev1:0.8b scored a correct "open TextEdit" at 0.12; `nimble`
separated it 0.998 vs 0.002 for "delete Documents") — pick
`nimble`/`clef-flash` or Jev for real use and watch the `judge … p=` notes
in `steps.jsonl`. Laya and GLiNER2.5-Decide are Python libraries without
this HTTP API; serve them behind a `/v1/systemone` shim to plug them in.

### API keys

Keys live in the login Keychain (service `com.matthew.s1.api-keys`, one
item per role: `decision`, `vlm`, `grounder`, `s2`) — set them in the
Connections sheet or `s1 key set <role>` (hidden prompt, or stdin), list
with `s1 key ls` (values never shown), delete with `s1 key rm <role>`.
Resolution order: `S1_<ROLE>_KEY` env → Keychain → legacy `key` in
config.json (saving a key to the Keychain removes the plaintext copy).

### Getting a model

Nothing to download for the `ax` brain — it's fully deterministic. For
`vlm`/`auto` you need a local model, which is one click or one command:

```bash
s1 models                      # installed models + the catalog with sizes
s1 pull gemma3:4b              # any ollama model — progress streams to stdout
```

The app's **Model library** sidebar does the same with a Download button
per catalog entry (vision models auto-assign to S1, text-only to S2), and
any already-installed model can be assigned from its ⋯ menu. No Ollama?
`brew install --cask ollama` — the section tells you so in-app.

## Everything lives in `~/.s1`

Every tunable is a plain file — edit in any editor, then `s1 doctor`
(or `s1 doctor --fix`, or Settings → General → "Run checks") validates
the whole directory in one pass. The defaults are tuned so the only edit
you'll ever *need* is a model name.

| File | What it holds |
|---|---|
| `config.json` | endpoints, models, locale, `sandbox`, `onboarded` — the master file |
| `providers.json` | the preset catalog behind every Settings menu and `--preset` flag — add or replace entries, `doctor` validates ids/roles/URLs |
| `convert.json` | your own unit + currency aliases for the launcher (`{"units": {"click": "km"}, "currencies": {"dolar": "usd"}}`) |
| `snippets.json` | launcher text snippets with `{clipboard}`/`{uuid}` placeholders |
| `memory.md` + `memory/<topic>.md` | remembered facts — [Agent Memory Repo](https://github.com/AgentMemoryRepo/agentmemoryrepo) layout: main list, per-topic files, auto `[[links]]` index. `remember that apps: my editor is Zed` files under `memory/apps.md` |
| `skills/<name>.json` | saved skills — a name + steps replayed through S1 and the safety gate |
| `tasks/<name>.txt` | persistent task library (`s1 run --task name`) |
| `srt-settings.json` | sandbox policy (see below) |
| `fx.json`, `usage.jsonl`, `artifacts/` | cached rates · metered calls · per-run logs |

### First-run setup

The app opens a setup wizard once (welcome → permissions → Cua Driver →
model keys → done); the terminal twin does the same:

```bash
s1 setup                     # guided: permissions → cua-driver → API keys → checks
s1 setup --non-interactive   # defaults only, no prompts
s1 setup --install-cua       # include the official Cua Driver install
s1 doctor                    # validate every file + tool above afterwards
```

Cua Driver is installed with CUA's own installer
(`cua.ai/driver/install.sh`) — recommended, and s1's executor prefers it
when present. Skip with `--no-cua`; re-run the wizard any time from the
app menu ("Set Up s1 Again…").

### Shell sandbox (optional, off by default)

`"sandbox": "srt"` in `config.json` (or `S1_SANDBOX=srt`, or Settings →
General) runs every shell step inside Anthropic's
[sandbox-runtime](https://github.com/anthropics/sandbox-runtime):
Seatbelt filesystem rules + a network allowlist from
`~/.s1/srt-settings.json` (written with a deny-most default on first
use — edit to taste). Requires `npm install -g @anthropic-ai/sandbox-runtime`;
if it's missing while enabled, shell steps fail closed instead of running
unsandboxed.

## Task library & run tooling

```bash
swift run s1 run --task open-app --policy ax        # goals live in tasks/*.txt — or ~/.s1/tasks/*.txt
swift run s1 metrics                                # stats for the newest run (or pass a run dir)
swift run s1 replay --dry-run                       # re-execute a recorded run (default: newest)
swift run s1 tasks                                # list what's in the library
```

A bare `--task name` searches `tasks/<name>.txt` in the current directory
first, then `~/.s1/tasks/<name>.txt` — drop files there for a persistent
library that works from anywhere.

Notes on the library: `download-file` expects a local server — run
`python3 -m http.server 8000` in a folder containing `test.zip` first
(Safari downloads it, then s1 opens the Downloads popover and verifies the
entry; on repeat runs Safari renames to `test-1.zip` — download fresh or
adjust the `verify` token). `read-screen` verifies text an earlier task
typed into TextEdit.

## Developer commands

```bash
swift run s1 ax                 # dump the frontmost app's AX tree (debug perceive)
swift run s1 ax Notes           # …or any running app by name / pid
swift run s1 capture --out out.png # one screenshot (checks Screen Recording grant)
swift run s1 say "halo" --language id-ID # TTS only
swift run s1 transcribe --file audio.aiff # STT only
swift run s1 run --policy scripted --plan plan.json # replay a hand-written plan
```

A plan file is a JSON array of steps — each `action` is the enum's
single-key form (`{"<case>":{params}}`):

```json
[{"action":{"openApp":{"name":"TextEdit"}},"rationale":"open"},
 {"action":{"typeText":"halo"},"rationale":"type"},
 {"action":{"done":{"summary":"ok"}},"rationale":"fin"}]
```

## Permissions (macOS TCC)

`s1 preflight` reports what's missing and prints exact instructions.

| Permission | Why |
|---|---|
| Accessibility | CGEvent input + reading the AX tree (the main perception path) |
| Screen & System Audio Recording | on-demand screenshots (ScreenCaptureKit) — **relaunch s1 after first grant** |
| Microphone | voice input only (P4) |
| Input Monitoring | the global hotkey (serve/app) — separate bucket from Accessibility; s1 requests it automatically the first time the tap can't be installed |

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
  Loop/      see → decide → gate → act → verify → log · Serve — always-on
             listen→run→speak daemon, auto-sleep, kill switch · Runner lock
  Hotkey/    passive CGEvent tap (listen-only): ⇧⇧ double-tap + ⌃⌥Space chord
Sources/s1/  CLI: preflight · run · demo · capture · ax · transcribe · say
             · listen · serve · status · stop · config · tasks · metrics
             · replay
Sources/S1App/ macOS app (SwiftUI, macOS 26 Liquid Glass): menu-bar companion
             (MenuBarExtra + hotkey + login item), mic + file STT, live step
             feed, brain/locale/model pickers, permission status, App Intents
```

## Safety

- Action classes: `read` always allowed · `reversible` logged · `irreversible` needs human.
- Hard deny-list: credentials/OTP/card data, purchases, destructive shell, power/session commands — never executed, escalated to a human.
- Secure-field guard: typing into a focused `AXSecureTextField` (or `axSetValue` on one) routes to `needsHuman` — the agent never fills a password box. Models see `[secure]` markers and a never-type rule.
- Kill-switch file checked every step (default path set per run).
- Stuck-loop guard: the same action three times in a row aborts the run (`stuckLoop`).
- Every run writes `artifacts/<ts>-<goal>/` with `steps.jsonl` — decided-by (`s1:`/`s2:`), confidence, gate verdict, verification result, escalation reason, and `modelReply` (the raw model output).

## How S1 thinks

- **Auto policy** (`--policy auto`, default): a real decision model when the VLM endpoint answers (one 3s probe at start, never per step), the deterministic AX policy when it doesn't — zero-config for both worlds.
- **AX policy** (`--policy ax`): zero model, parses `open X, type Y, done` intents and executes deterministically — the baseline every smarter S1 must beat. The grammar is wider than open/type: window + tab + app control (`close`, `new tab`, `back`, `reload`, `switch`, `lock`, `zoom in`), media keys (`play`, `skip`, `mute`, `volume up`), click flavors (`double click`, `klik kanan`), `find X` (⌘F + type), and Indonesian mirrors throughout — all keyCombos, no model call.
- **VLM policy** (`--policy vlm`): goal → deterministic intent cursor (shared grammar with AX policy) → the model grounds ONE intent per step. Small local models decide actions; they don't track whole plans. Truncated/malformed JSON is salvaged field-by-field before a strict-JSON retry.
- **S2** (`--s2`): any OpenAI-compatible endpoint; called only below the confidence threshold, with the reason logged.
- Defaults on this project: `gemma3:4b` via Ollama for VLM and S2 (benchmarked on an arm64 VM: correct JSON ≈1min/step on CPU; much faster on a real Mac). Set `S1_VLM_MODEL` / `S1_S2_MODEL` to swap.

### Permissions caveat

macOS attributes TCC grants to the *responsible* process: run `s1` from Terminal and **Terminal** needs the Accessibility / Screen Recording / Speech Recognition grants — not just the `s1` binary. `s1 preflight` reports what the current host is missing.

## Known limits (honest)

- **Small GUI models are still young.** `gemma3:4b` is the interim default
  because it's the smallest model we benchmarked that finishes multi-step
  goals; GUI-tuned models (Fara1.5, GUI-Owl, UI-TARS, Holo) are the
  upgrade path — the protocol makes swapping a config edit, not a refactor.
- **AX coverage isn't everything.** Apps that don't expose an
  accessibility tree (some Electron, games, remote desktops) fall back to
  screenshot-grounded VLM steps — slower and model-dependent by design.
- **Voice needs real audio hardware.** `s1 listen`/`serve` mic paths need a
  microphone + Speech Recognition grant; `transcribe --file` is the
  headless/testable path.
- **iOS is out of scope.** Apple gives no third-party AX/event-injection
  APIs on iOS — full control there is Siri/Shortcuts-only territory.
  (Design notes in `PLAN.md` §7.)
- **TCC belongs to the responsible process** — grants follow your terminal
  app when running via `swift run` or a CLI in a shell.

## Contributing

See `CONTRIBUTING.md` — setup, how to test (unit + real TCC runs), conventions, PR flow.

## Roadmap

P0 harness ✅ · P1 real run ✅ · P2 S1 AX/VLM + S2 escalation ✅ · P3 vision on-demand ✅ · P4 voice ✅ · P5 task library ✅ · P6 replay + metrics ✅.

See `PLAN.md` for the research and model choices (Fara1.5-4B, GUI-Owl-1.5-2B, Holo 4, FluidAudio, WhisperKit — all verified actively maintained as of Oct 2026).
