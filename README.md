<p align="center"><img src="assets/logo/s1.svg" width="112" alt="s1"></p>

<h1 align="center">s1</h1>

<p align="center"><b>Say what you want done. s1 does it on your Mac and shows every step it took.</b></p>

<p align="center">
  <a href="https://github.com/Matthew-Eucaristo/s1/actions/workflows/swift.yml"><img src="https://github.com/Matthew-Eucaristo/s1/actions/workflows/swift.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/Matthew-Eucaristo/s1/releases"><img src="https://img.shields.io/github/v/release/Matthew-Eucaristo/s1?include_prereleases&label=release&color=orange" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT"></a>
</p>

<p align="center"><a href="https://s1-mac.pages.dev">Website</a> · <a href="#install">Install</a> · <a href="#models">Models</a> · <a href="#the-command-line">CLI</a> · <a href="SECURITY.md">Security</a></p>

<p align="center"><img src="assets/app.png" width="800" alt="The s1 window: run history in the sidebar, a conversation of spoken commands with their steps, and a password step stopped by the safety gate"></p>

s1 is a voice-first agent for macOS. Double-tap <kbd>⇧</kbd> anywhere, say
*“open Notes and write the shopping list”*, and watch it happen. It reads the
screen through the Accessibility tree, acts like you would, checks its work,
and keeps the evidence.

Most commands never need a model: a built-in grammar handles the everyday
(opening apps, typing, shortcuts, media keys) instantly. On top of it sit two
models, both optional and both yours to pick:

- **Judge (System 1):** a small, fast decision model that picks the right control
  when the grammar isn't sure, and checks the goal really happened.
- **Reasoner (System 2):** an LLM that takes over when something is new.

Everything dangerous waits for you.

> **Public beta (v0.x).** It works and it's tested, and it's still sharpening.
> Read [SECURITY.md](SECURITY.md) before letting it drive a machine you care about.

## Highlights

- **Talk from anywhere.** <kbd>⇧</kbd><kbd>⇧</kbd> or <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Space</kbd>
  wakes the listener; talk over s1 to interrupt it. A Liquid Glass pill under
  the notch shows what it hears and what it's doing.
- **A full keyboard and mouse, by voice, instantly.** The built-in grammar
  (English and Indonesian) opens apps, types, presses any key or chord
  (`press f5`, `press tab 3 times`, `tekan 1 2 3`), clicks, double/right-clicks,
  drags (`drag report.pdf to Trash`), hovers, scrolls (`scroll down a lot`,
  `scroll to top`), picks from dropdowns (`pilih Large dari Size`), edits text
  (`hapus kata ayam`), copies and pastes, and drives tabs, windows and media
  keys. Zero model calls, zero latency; the Reasoner is only for thinking.
- **Knows the Mac.** Built-in Mac skills open every System Settings pane by
  name (*“buka pengaturan Wi-Fi”*, *“open battery settings”*), the standard
  folders (*“open Downloads”*), and the system actions (Mission Control, show
  desktop, Spotlight, emoji picker, Force Quit, screenshot an area, screen
  recording, brightness, keyboard language). *“What time is it?”* and
  *“baterai berapa?”* are answered on the spot. The Reasoner knows the same
  list and hands these to System 1.
- **One model per job, any provider.** Connect TypeSafe, OpenCode Go, OpenAI,
  OpenRouter, Groq, Gemini, xAI, DeepSeek, Liquid AI, Cloudflare, Ollama,
  LM Studio or any OpenAI-compatible server, then pick a Judge (System 1) and
  a Reasoner (System 2). No account required to start.
- **Looks when it can.** If your Judge reads images it sees the screen; if
  not, your Reasoner does; if neither can, s1 uses the accessibility tree.
- **Every step is evidence.** Each run keeps its steps, who decided them, why,
  and screenshots. Browse them in the app's history or `~/.s1/artifacts`.
- **Careful by design.** A safety gate runs before every action. Passwords,
  purchases and anything irreversible stop and ask. The Judge can only add caution.
- **Great defaults, all of it yours.** Works the moment it opens, and every
  default is a setting. Models, vision and voices are also a CLI command and a
  line in `~/.s1/config.json`. See [Configure and extend](#configure-and-extend).
- **Native and light.** Swift 6, SwiftUI, App Intents, no private APIs.
  Idle uses 0% CPU and no microphone.

## Install

```bash
brew tap Matthew-Eucaristo/tap
brew trust Matthew-Eucaristo/tap     # once, on Homebrew ≥ 4.4
brew install --cask s1               # the app, with the `s1` CLI on your PATH
```

Or download `S1-*-app.zip` from [Releases](https://github.com/Matthew-Eucaristo/s1/releases/latest)
and drag S1 to Applications.

<details>
<summary><b>First launch:</b> “Apple could not verify S1…”</summary>

The beta is developer-signed but not yet notarized. Allow it once, any of:

- System Settings → Privacy & Security → **Open Anyway**
- `xattr -d com.apple.quarantine /Applications/S1.app`
- `brew install --cask s1 --no-quarantine`

Notarization is planned for 1.0.
</details>

<details>
<summary><b>Uninstall</b></summary>

```bash
s1 serve --uninstall                 # only if you installed the launchd listener
brew uninstall --cask s1 --zap       # app + ~/.s1 + Library traces
```
</details>

## Get started

1. **Open s1.** Setup walks you through permissions; only **Accessibility** is
   required.
2. **Try it.** Double-tap <kbd>⇧</kbd> and say *“open Notes”*, or type in the window.
3. **Optionally, give it a brain.** Settings → Models → **Add Provider**. The
   recommended pair is **TypeSafe** (Jev, the Judge) and **OpenCode Go**
   (DeepSeek, the Reasoner); Ollama keeps everything on your Mac.

## How it works

```
 you ─▶ voice / text ─▶ built-in grammar ─▶ Judge (System 1) ─▶ safety gate ─▶ act ─▶ verify ─▶ log
                        no model, instant   picks + checks           ▲
                                                  │ unsure           │
                                                  └─▶ Reasoner (System 2) ─┘

 screen ─▶ the Judge if it reads images, else the Reasoner, else nobody (accessibility tree only)
```

- **The built-in grammar** parses the request into intents and runs the ones it
  knows, deterministically. No model, no network.
- **The Judge (System 1)** is a fast decision model that answers typed questions
  about the screen; it never writes plans. It steps in where it adds something:
  when several controls match ("click Send" with two Send buttons) it picks
  one, when the grammar's match is fuzzy it scores the step, and after typing
  or clicking it checks the goal really happened. If it reads images, it looks
  at the screen for those questions only. It can only lower confidence; exact
  steps (open an app, press a key) stay instant. No Judge set: the grammar
  runs alone.
- **The Reasoner (System 2)** gets the step when the grammar doesn't know it or
  confidence is low: the goal, the run so far, the accessibility tree and, if it
  can read images, a screenshot. It plans: new tasks come back as plain steps
  ("open Mail", "click Send", "type …") that System 1 runs fast, with the Judge
  picking targets. It can also answer questions directly.
- **The gate** classifies every action (`read`, `reversible`, `irreversible`),
  blocks credentials and payments outright, and stops on secure text fields.

In the app, each step carries a tag: **S1** for the fast path (grammar, checked
by the Judge when one is set), **S2** for the Reasoner.

## Models

s1 has two ideas: **providers** and **roles**. A provider is one account or
server with one API key (kept in your login Keychain). A role is a job, and
each job takes one model:

| Role | Job | Unset means |
|---|---|---|
| `judge` | **Judge (System 1):** a fast decision model that picks the right control when the grammar isn't sure and checks the goal is done (System One API) | grammar only |
| `reasoner` | **Reasoner (System 2):** an LLM that plans what the grammar can't and answers questions | no escalation |
| `transcribe` | Cloud speech-to-text for each finished voice turn | on-device Apple speech |
| `speak` | A cloud voice for replies | Apple voices |

**Seeing the screen** is a capability of the models you pick, not another
role. If the Judge reads images (d1 paid tier, Clef) it gets a screenshot with each
step; otherwise the Reasoner gets one with every step it takes over (Gemini,
GPT-5, Claude, Llama 4 Scout, Qwen3-VL…); if neither can, s1 works from the
accessibility tree alone. One switch, "Let models see the screen", turns it
off. Settings marks every model that sees.

Connecting a provider fills an empty Judge or Reasoner with its recommended
model. Voices never switch on by themselves: audio leaves your Mac only when
you choose a cloud model for it.

| Provider | Good for | |
|---|---|---|
| TypeSafe | Jev, the recommended Judge | key |
| OpenCode Go | DeepSeek V4.1 Flash, the recommended Reasoner | key |
| OpenAI | GPT-5 (sees), transcription, voices | key |
| OpenRouter | Every major model behind one key, Claude included | key |
| Groq | Llama 4 Scout (sees), Whisper, Orpheus voices | key |
| Google Gemini · xAI · DeepSeek | Reasoners (System 2) | key |
| Liquid AI · Cloudflare Workers AI | Judges (System 1) that see the screen | key |
| Ollama · LM Studio | Open models on your Mac | local |
| Custom server | vLLM, MLX, Speaches, your own shim | optional key |

In the app it's Settings → Models. From the terminal:

```bash
s1 connect opencode                          # prompts for the key, checks it, fills the Reasoner
s1 connect ollama
s1 use judge ollama/clef-flash               # provider/model; the model id may contain slashes
s1 use reasoner openrouter/anthropic/claude-sonnet-4.5
s1 use speak off                             # back to Apple voices
s1 models                                    # what each provider offers, live
s1 providers                                 # what's connected, checked live
```

Both write the same `~/.s1/config.json`:

```json
{
  "providers": [{ "id": "typesafe" }, { "id": "opencode" }],
  "models": {
    "judge": "typesafe/jev-latest",
    "reasoner": "opencode/deepseek-v4.1-flash"
  },
  "vision": true
}
```

For one-off runs and CI: `S1_REASONER=groq/openai/gpt-oss-120b`,
`S1_GROQ_KEY=…`, `S1_JUDGE=off`, `S1_VISION=off`.

## Voice

Speech runs on-device with Apple's SpeechAnalyzer. **Automatic** listens in
English and your Mac's language at once; 14 languages are supported, with
English and Indonesian verified end to end. Commands the grammar can't parse go
to the Reasoner, which reads any language.

- **Interrupt:** talk over s1 while it works or speaks and it stops, then
  listens for what's next (echo-cancelled, so its own voice doesn't trip it).
- **Custom words:** add names it misspells; it already learns your installed
  apps, skill names and remembered names.
- **Edit by voice:** *“hapus kata ayam”*, *“replace cat with dog”* edit the focused
  text in place (last whole-word match; Undo works).
- **Dictate anywhere:** hold <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd>, speak, release;
  the text lands where you were typing.

## Everything else

| | |
|---|---|
| <kbd>⇧</kbd><kbd>⇧</kbd> · <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Space</kbd> | Talk to s1 from anywhere |
| <kbd>⌥</kbd><kbd>Space</kbd> | Launcher: apps, files, snippets, calculator, unit and currency conversion, window layouts |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>D</kbd> | Dictate into any app |
| *“remember that my editor is Zed”* | Memory in `~/.s1/memory.md`, never passwords or keys |
| *“what's my editor?”* · *“open my editor”* | Answered and resolved from memory instantly, no model |
| *“save that as a skill called morning setup”* | Replay a sequence by name, every step through the gate |
| Siri & Shortcuts | “Ask s1 to …”, “Wake s1” |

## Configure and extend

s1 ships with the defaults we'd pick for you, and every one of them can change.

| Default | Change it |
|---|---|
| Built-in grammar, no model needed | Settings → Models, `s1 use`, `S1_JUDGE` / `S1_REASONER` |
| Recommended models filled in when you connect a provider | Any model the provider lists, or `provider/model` by hand |
| Models that can see get screenshots | "Let models see the screen", `"vision": false`, `S1_VISION=off` |
| On-device speech and Apple voices | Settings → Voice, `s1 use transcribe` / `s1 use speak` |
| Talk over s1 to stop it; spoken replies | Settings → Voice |
| Status pill under the notch, memory on | Settings → General |
| s1 orange accent | Settings → General → Appearance → Accent color (or follow macOS) |

Ways to extend it today:

- **Any model server.** The Custom provider takes any OpenAI-compatible endpoint
  (vLLM, MLX, Speaches, your own shim).
- **Your own brain.** `Policy` and `Reasoner` are small Swift protocols; see
  [docs/adding-a-brain.md](docs/adding-a-brain.md).
- **Skills, snippets, Shortcuts.** Save a sequence as a skill by voice, add
  launcher snippets, or drive s1 from Siri and Shortcuts.
- **Scripts.** The `s1` CLI runs, inspects and replays everything the app does.

A plugin system for new actions, providers and skills is on the roadmap; the
provider catalog and role design are built so plugins slot in without changing
how you configure s1.

## The command line

The app and the CLI share one config, one history and one brain.

| | |
|---|---|
| `s1 run --goal "open Notes"` | Run a command (`--dry-run` touches nothing, `--policy ax` skips the Judge) |
| `s1 listen` · `s1 serve` | One voice command · the always-on listener (`--install` for launchd) |
| `s1 providers` · `connect` · `disconnect` | Manage providers |
| `s1 use` · `s1 models` · `s1 pull` | Assign roles · see choices · download an Ollama model |
| `s1 config` · `s1 doctor` | What's resolved · validate every file in `~/.s1` |
| `s1 status` · `s1 stop` · `s1 clean` | Listener state · stop everything · delete run history |
| `s1 metrics` · `s1 replay` | Inspect or re-run a recorded run |
| `s1 setup` | The onboarding flow, in the terminal |

`s1 help <command>` has the details.

## Everything lives in `~/.s1`

| File | |
|---|---|
| `config.json` | Providers, roles, voice and app settings |
| `memory.md`, `memory/` | Remembered facts ([Agent Memory Repo](https://github.com/AgentMemoryRepo/agentmemoryrepo) layout) |
| `skills/*.json` | Saved skills |
| `snippets.json`, `convert.json` | Launcher snippets and unit/currency aliases |
| `artifacts/` | One folder per run: `meta.json`, `steps.jsonl`, `screens/` (newest 50 kept) |
| `usage.jsonl` | Token counts per model call, never prompts or replies |

Keys are never written here. `s1 doctor` checks it all.

## Permissions

| | |
|---|---|
| **Accessibility** | Required: reading the UI and sending input |
| Input Monitoring | The <kbd>⇧</kbd><kbd>⇧</kbd> shortcut |
| Microphone | Voice |
| Screen Recording | Screenshots for verification and models that see |

macOS ties grants to the app that runs s1: when you use the CLI from a
terminal, the terminal needs them. `s1 preflight` tells you what's missing.

## Build from source

```bash
git clone https://github.com/Matthew-Eucaristo/s1.git && cd s1
swift test                          # no permissions needed
./scripts/dev-cert.sh               # once: keeps TCC grants across rebuilds
./scripts/make-app.sh && open dist/S1.app
```

`docs/adding-a-brain.md` shows how to write your own `Policy` or `Reasoner`.

## Honest limits

- Apps without an accessibility tree (some games, remote desktops, a few
  Electron apps) need a Reasoner that sees the screen: slower, and only as
  good as the model.
- Small local GUI models are still young. The grammar plus a hosted Reasoner is
  the most reliable setup today.
- iOS is out of scope: it offers no cross-app accessibility or input APIs.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Translations are especially welcome:
copy `Sources/S1App/id.lproj` to your language, add replies in
`SpokenLanguage`, and extend the grammar's verb tables.

MIT licensed. Built on open source credited in [ATTRIBUTIONS.md](ATTRIBUTIONS.md).
