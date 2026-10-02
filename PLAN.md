# S1 — Final Plan

Voice-first macOS agent. Dua lapis: **System 1** (cepat, lokal, bisa diganti-ganti di balik protokol) menangani mayoritas langkah; **System 2** (LLM, lokal atau cloud) hanya dipanggil saat S1 tidak yakin. Swift native. MIT. Public OSS.

> Status: **rencana untuk review** — belum ada kode ditulis.

---

## 0. Angka dulu (hasil research yang terverifikasi)

| Klaim | Bukti |
|---|---|
| VM ini macOS **26.5.2 arm64**, Xcode 26.6, Swift 6.3.3 | `sw_vers`, `xcodebuild -version` — jadi P1 bisa dites langsung di sesi ini |
| Apple Speech on-device: **63 locale**, termasuk `id-ID` (Indonesia) + `en-ID` | diverifikasi dengan menjalankan `SFSpeechRecognizer.supportedLocales()` di VM ini |
| `SpeechAnalyzer`/`SpeechTranscriber` = API STT baru macOS 26, on-device, streaming via `AsyncSequence` | WWDC25 session 277 + docs |
| CGEvent posting butuh `kTCCServiceAccessibility`; event tap butuh hal sama | Apple docs + OSS TCC scripts |
| Screen Recording = TCC service terpisah; **setelah grant pertama app harus relaunch** (invariant yang menjebak banyak implementasi) | dokumentasi macos-app-scaffold + Apple DTS |
| macOS 26 menggabungkan izin sebagai "**Screen & System Audio Recording**" | docs xa11y.dev |
| Accessibility API **tidak kompatibel dengan App Sandbox** → distribusi luar App Store (Developer ID + notarization nanti) | Apple docs |
| Peekaboo (steipete): MIT, 97% Swift, expose `PeekabooAutomationKit` sebagai SwiftPM lib | Package.swift di repo |
| cua-driver (trycua): MIT, **Rust daemon**, MCP over stdio, background input tanpa curi fokus | repo README |
| FluidAudio: Apache-2.0 — VAD Silero + Parakeet STT + TTS di ANE; **aktif: v0.15.6 rilis 19 Agu 2026** | LICENSE + releases |
| WhisperKit (argmax-oss-swift): MIT; **aktif: v0.18.0 rilis 1 Apr 2026** | releases |
| Holo1.5-7B: Apache-2.0, SOTA UI localization (avg 77.32 vs UI-TARS-1.5 70.45); **Holo 4** baru rilis 28 Sep 2026 (27B + 35B-A3B MoE, open weights + GGUF) | HF model card + The Register |
| GUI-Owl-1.5 (Alibaba, Feb 2026): keluarga **2B/4B/8B/32B** di atas Qwen3-VL, multi-platform GUI | repo Mobile-Agent-v3.5 |
| Fara1.5 (Microsoft, 22 Jul 2026): **4B/9B/27B** di atas Qwen3.5, MIT; S2-friendly (dilatih pause di aksi irreversible & tanya user saat ambigu) | repo + HF |
| S2 lokal ringan: **Qwen 3.5 4B/9B** (~2.5–5 GB), **Gemma 4 E4B** (multimodal), **Gemma 4 26B-A4B** (reasoning terbaik, ~15 GB) | benchmark 2026 |
| ORB (voice agent on-device): **tanpa LICENSE** → boleh dipelajari, tidak boleh dicopy | dicek langsung |

---

## 1. Keputusan arsitektur (dari research)

### 1.1 Bahasa & kemasan
- **Swift 6 + SwiftPM** multi-target. Logika inti di library `S1Core` (testable, `swift test` di CI), executable tipis `s1` (CLI), target `S1App` (menu bar, LSUIElement) di fase suara.
- `.app` bundle dibuat via `scripts/package-app.sh` (Info.plist + binary SwiftPM) — tidak perlu `.xcodeproj` yang dikomit. XcodeGen opsional kalau nanti app-nya besar.
- **Tidak sandboxed.** Distribusi: unsigned dulu untuk dev → Developer ID + notarize saat rilis.

### 1.2 Modul (semua di balik `protocol`, bisa di-mock)
```
S1Core/
  Perceive/    ScreenCapture (SCScreenshotManager one-shot) · WindowList · AXTree
  Act/         MouseKeyboard (CGEvent) · AXActions (AXPress, AXSetValue) · Gate
  Policy/      protocol Policy { decide(obs) -> Decision(action, confidence, note) }
               impl: DummyPolicy → AXPolicy (deterministik) → VLMPolicy (endpoint)
  Reasoner/    protocol Reasoner (S2) → OpenAICompatible (Ollama/MLX/LM Studio/cloud)
               + Anthropic adapter
  Voice/       protocol STTEngine { AppleSpeech (default) | FluidAudio | WhisperKit }
               VAD · PushToTalk (hotkey global) · protocol TTSEngine { AVSpeech }
  Loop/        AgentLoop: perceive → gate → decide → act → verify → log
  Safety/      ActionClass (read/reversible/irreversible) · DenyList · KillSwitch
  Preflight/   TCC checks (AX, ScreenRecording, Mic, Speech) + relaunch invariant
  Artifacts/   RunLogger → <run>/steps.jsonl + screenshots/ + meta.json
```
Mengapa dipisah begini: mengikuti brainstorming + praktik Peekaboo/cua — bedanya kita S1/S2-native, bukan single-brain.

### 1.3 System 1 adalah protokol, bertingkat implementasinya
```swift
protocol Policy {
    func decide(_ obs: Observation, goal: Goal) async throws -> Decision
}
struct Decision { var action: Action?; var confidence: Double; var rationale: String }
```
Implementasi berurutan (semua bisa dipakai user):
1. **`DummyPolicy`** (P0): untuk uji harness.
2. **`AXPolicy`** (P1.5): tanpa model — fuzzy-match intent ke elemen AX (button "Save", field "Name"). Confidence = skor match. Murah, instan, offline, dan menangani banyak langkah nyata (klik tombol bernama, isi field berlabel).
3. **`VLMPolicy`** (P2): model lokal di balik **OpenAI-compatible endpoint** → user pilih backend: `mlx_vlm.server`, Ollama (GGUF), LM Studio, atau vLLM. Kandidat (diverifikasi Okt 2026, urutan ringan→berat):
   - **GUI-Owl-1.5-2B/4B** — paling ringan, native GUI agent (Qwen3-VL), untuk Mac 16 GB.
   - **Fara1.5-4B** (MIT) — SOTA size-class, dilatih pause di aksi irreversible + tanya user saat ambigu → cocok safety model kita.
   - **Holo1.5-7B** (Apache) / **Holo 4 35B-A3B** (open weights, GGUF, ~4B aktif per token — "best" tier untuk RAM besar).
   Default yang disarankan: **Fara1.5-4B** untuk sebagian besar Mac; GUI-Owl-2B untuk yang paling hemat; Holo 4 untuk maksimal.

Confidence hibrida (model tidak kalibrated): skor match AX + confidence verbal model + **verify-after-act** (re-perceive, cek perubahan yang diharapkan). Di bawah ambang `conf_threshold` → eskalasi S2, dicatat `reason` di log.

### 1.4 System 2
`protocol Reasoner` dengan dua adapter: **OpenAI-compatible** (satu endpoint menutupi Ollama, LM Studio, mlx server, OpenRouter, OpenAI) dan **Anthropic**. API key di **Keychain** (`SecItem`), config non-rahasia di `~/.config/s1/config.json`. Nol kredensial di repo.

### 1.5 Perception: AX-first, screenshot on-demand
- Jalur utama = **AX tree** (struktur, role, label, position) + window list. Murah, cepat, bisa offline.
- **Screenshot hanya saat perlu** (VLM dipanggil, verifikasi visual, debugging) — alasan dicatat per capture, sesuai catatan biaya token vision (mis. DeepSeek ~800px/384 tok per image).
- `SCScreenshotManager.captureImage` (one-shot, macOS 14+) — bukan `SCStream` kontinu; hemat baterai, cocok dengan stepwise loop.

### 1.6 Suara (P4)
- **STT default: `SpeechAnalyzer`/`SpeechTranscriber`** — built-in, on-device, 63 locale terverifikasi termasuk `id-ID`. Gratis, tanpa download model, paling native.
- Opsional: **FluidAudio Parakeet** (Apache; p50 ~182 ms, tapi v3 hanya bahasa Eropa → untuk English-first low latency) dan **WhisperKit** (MIT; large-v3 multilingual termasuk Indonesia).
- **VAD**: FluidAudio Silero VAD (sudah satu paket) atau endpointing bawaan SpeechTranscriber; mode **push-to-talk** via hotkey global (Carbon `RegisterEventHotKey`, tidak butuh AX).
- **TERBANGUN — always-on companion (di luar fase P, permintaan owner)**: `Serve` daemon `idle ⇄ listening` (hear → run → speak → hear, stop-phrase, auto-sleep; idle = 0 mic/CPU) + global hotkey **⇧⇧ / ⌃⌥Space** via `CGEvent.tapCreate` listen-only (NSEvent monitor tidak pernah deliver di host CLI — fakta platform) + app `MenuBarExtra` (badge state, Listen, Launch at login `SMAppService`). Perception membawa `AppState[]` semua app + window titles; `open X` resolve via Spotlight `mdfind`. Catatan: hotkey pakai CGEvent tap (butuh Accessibility + Input Monitoring), bukan Carbon — Carbon hanya menangkap keyDown target dan tidak bisa double-tap modifier.
- **TTS**: `AVSpeechSynthesizer` on-device (ada voice Indonesia) — default, sejalan "TTS belum wajib". Opsional Kokoro via FluidAudio (English).

### 1.7 Dependensi OSS (diputuskan dari lisensi + integrasi)
| Pakai? | Proyek | Lisensi | Peran |
|---|---|---|---|
| **Ya (opsional adapter)** | `cua-driver` (trycua) | MIT | Backend Act alternatif via subprocess/MCP; direkomendasikan nyala saat stabil — background input tanpa curi fokus. Tidak di-embed (Rust daemon), dipanggil sebagai proses. |
| **Ya (referensi + opsional lib)** | Peekaboo / AXorcist | MIT | Acuan desain `see/click/type` + `postToPid`; `PeekabooAutomationKit` bisa jadi adapter Act opsional. |
| **Ya (opsional)** | FluidAudio | Apache-2.0 | VAD + Parakeet STT + TTS alternatif. |
| **Ya (opsional)** | WhisperKit | MIT | STT multilingual alternatif (Indonesia OK). |
| **Model** | Holo1.5-7B / Fara-7B / UI-TARS | Apache/MIT | Kandidat VLMPolicy (S1 visual). |
| **Studi saja** | ORB, vox-ops, agent-swift, xa11y, sai | tanpa lisensi/MIT | Referensi desain pipeline suara & AX-refs; tidak dicopy. |
| Atribusi | semua di atas | — | `ATTRIBUTIONS.md` wajib di repo. |

Prinsip: **kode inti sendiri dulu** (AX/CGEvent/SCK tipis ~ratusan baris — sejalan "komponen minimal, tiap dep harus ada alasan"), adapter OSS di tepi via protokol.

### 1.8 Safety model (non-negotiable, dari konsep)
- Kelas aksi: `read` (selalu) · `reversible` (boleh, dicatat) · `irreversible` (butuh `--allow-irreversible` + konfirmasi).
- Deny-list keras: password/OTP/CVC, pembelian, kirim pesan tanpa konfirmasi → selalu `needs_human`.
- Kill switch: global hotkey (mis. `⌃⌘.` ) dicek **tiap langkah** + `stop` file sentinel.
- Tiap run → `artifacts/<timestamp>/` : `steps.jsonl`, `screens/`, `meta.json` (config, versi, policy yang dipakai).
- Dry-run default aman: loop jalan penuh, Act dimatikan (`--dry-run`).

---

## 2. Struktur repo

```
s1/
├── Package.swift                # swift-tools 6.x, macOS 15+ (26 untuk SpeechAnalyzer gated)
├── README.md                    # 3 langkah: clone → swift test → dry-run
├── LICENSE                      # MIT (sudah ada)
├── ATTRIBUTIONS.md              # kredit + lisensi OSS yang dipakai/dirujuk
├── Sources/
│   ├── S1Core/                  # semua modul §1.2
│   ├── s1/                      # CLI (ArgumentParser)
│   └── S1App/                   # menu bar app (mulai P4)
├── Tests/S1CoreTests/           # gate, jsonl format, policy mock, replay
├── scripts/package-app.sh       # bikin S1.app dari binary
└── docs/                        # architecture.md · permissions.md · providers.md · safety.md
```
Deps SwiftPM (kept minimal): `swift-argument-parser` (CLI), `FluidAudio` (opsional, P4), `WhisperKit` (opsional). Tachikoma tidak perlu — provider HTTP tipis sendiri (~150 baris) sudah cukup.

---

## 3. Fase & kriteria terima (mengikuti konsep, disesuaikan research)

| Fase | Isi | Kriteria terima |
|---|---|---|
| **P0** | Scaffold + Gate + steps.jsonl + Preflight + DryRun + DummyPolicy + unit test | `swift test` lulus (gate tolak irreversible, format log benar); README 3 langkah |
| **P1** | Run nyata di VM ini: grant TCC, screenshot, gerakkan kursor, ketik di TextEdit, verifikasi baca ulang | ≥10 langkah dalam 1 run, artefak screenshot, ≥1 langkah verified nyata |
| **P2** | AXPolicy → VLMPolicy + Reasoner(S2) + ambang eskalasi | 1 run S1 ≥ mayoritas langkah; semua eskalasi S2 tercatat + alasan |
| **P3** | Screenshot on-demand + set-of-marks opsional; AX tetap jalur utama | Tiap capture tercatat alasannya |
| **P4** | Voice: PTT hotkey → SpeechAnalyzer → intent → loop; AVSpeech keluar | Ucap tugas → dikerjakan → diucapkan; transkrip di log |
| **P5** | Task library: 5 tugas ber-uji (open app, isi form, baca nilai, download, verifikasi) | Tiap tugas punya bukti verifikasi |
| **P6** | Replay dari steps.jsonl, metrik token/biaya, taksonomi gagal, eskalasi manusia | Tidak pernah lanjut diam-diam saat macet |

---

## 4. Risiko & mitigasi (dari research)

1. **TCC di VM** — hambatan pertama, sama seperti prediksi. Mitigasi: sesi ini Mac VM punya GUI aktif → bisa klik prompt di System Settings; preflight mengecek dan memberi instruksi persis. Invarian *relaunch-setelah-grant* dienkode di `Preflight`.
2. **Biaya/latensi screenshot** — desain AX-first menyelesaikan mayoritas; capture on-demand.
3. **Confidence model tidak kalibrated** — jangan andalkan logits saja: gabungkan match-score + verbal + verify-after-act.
4. **Model 7B ≈ 4–9 GB** — lazy download via provider (Ollama/HF cache), didokumentasikan; S1 berfungsi tanpa model (AXPolicy).
5. **Apple Silicon only** — target memang Apple Silicon (MLX/ANE); Intel tidak didukung (dinyatakan di README).
6. **macOS 26 rename TCC** — preflight menulis nama izin yang benar per-versi.

## 5. Estimasi

- **P0 + P1**: bisa selesai **dalam sesi ini** — VM ini Mac 26.5.2 + Xcode + GUI. (Butuh 1× klik izin di System Settings — aku bisa lakukan di GUI VM ini.)
- **P2**: 1 sesi (API endpoint + kebijakan).
- **P4 (suara)**: 1 sesi.
- Selebihnya incremental.

## 6. Yang belum diputuskan (butuh oke dari kamu)

1. Mulai **P0+P1 sekarang** di sesi ini? (Kode + uji nyata di VM ini.)
2. Default driver: `cua-driver` dijadikan adapter opsional sejak P2, atau tunda sampai core stabil?
3. App bundle menubar (P4) — cukup `package-app.sh`, atau mau XcodeGen dari awal?
