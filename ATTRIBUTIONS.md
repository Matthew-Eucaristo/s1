# Attributions

s1 builds in the open on public OSS. Components we depend on directly:

| Project | License | Used for |
|---|---|---|
| [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | CLI |
| [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 | VAD (Silero), Parakeet STT, on-device TTS (optional, P4) |
| [argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) | MIT | multilingual on-device STT (optional, P4) |
| [trycua/cua](https://github.com/trycua/cua) (`cua-driver`) | MIT | optional Act backend via MCP/subprocess (P2+) |
| [steipete/Peekaboo](https://github.com/steipete/Peekaboo) + [AXorcist](https://github.com/steipete/AXorcist) | MIT | design reference; optional adapter for Perceive/Act |

Model weights (downloaded by the user, never vendored):

| Model | License | Role |
|---|---|---|
| [microsoft/Fara1.5](https://github.com/microsoft/fara) (4B/9B/27B) | MIT | System-1 VLM candidate — trained to pause on irreversible actions and ask when ambiguous |
| [GUI-Owl-1.5](https://github.com/X-PLUG/MobileAgent) (2B–32B, Qwen3-VL base) | Apache-2.0 | lightest native-GUI VLM for S1 |
| [Hcompany/Holo1.5](https://huggingface.co/Hcompany/Holo1.5-7B) + Holo 4 | Apache-2.0 / open weights | SOTA UI localization, larger-tier S1 |
| [bytedance/UI-TARS](https://github.com/bytedance/UI-TARS) | Apache-2.0 | S1 VLM candidate |
| OpenCUA (XLANG) | Apache-2.0 | S1 VLM candidate |

Runtime endpoints s1 talks to (installed by the user, OpenAI-compatible — no code vendored):

- [ollama/ollama](https://github.com/ollama/ollama) — MIT; default local endpoint (`http://localhost:11434/v1`).
- LM Studio, `mlx_lm.server`/`mlx_vlm.server` (MLX), vLLM, OpenRouter/OpenAI — same wire format, swappable via `S1_*_BASE`/`S1_*_MODEL`.

Design references only (not copied — no license file / studied):

- [settylokesh/ORB](https://github.com/settylokesh/ORB) — on-device voice agent for macOS.
- [beastoin/agent-swift](https://github.com/beastoin/agent-swift) — AX snapshot + ref CLI pattern.
- [xa11y](https://github.com/xa11y/xa11y) — MIT; cross-platform AX for e2e tests; macOS-26 TCC notes.
- [EricGrill/vox-ops](https://github.com/EricGrill/vox-ops) — push-to-talk voice pipeline architecture.
- [xueshiqiao/macos-app-scaffold](https://github.com/xueshiqiao/macos-app-scaffold) — the ScreenCaptureKit relaunch invariant.
