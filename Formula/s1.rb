# Homebrew formula for s1.
#
# Two ways to ship:
#   1. Personal tap (recommended to start): create repo `Matthew-Eucaristo/homebrew-tap`,
#      copy this file to `Formula/s1.rb` there. Users then run
#        brew tap Matthew-Eucaristo/tap
#        brew install s1
#   2. homebrew-core: submit this file upstream once the project is notable.
#
# Release flow: `git tag vX.Y.Z && git push --tags`, build the binary with
# `scripts/release.sh X.Y.Z`, attach the tarball to the GitHub Release, then
# update `url` + `sha256` below.
class S1 < Formula
  desc "Voice-first macOS agent — fast System 1 + LLM System 2, accessibility-driven"
  homepage "https://github.com/Matthew-Eucaristo/s1"
  license "MIT"
  url "https://github.com/Matthew-Eucaristo/s1/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # filled at release

  # Builds from source — needs a recent Xcode toolchain (Swift 6 / macOS 26 SDK).
  depends_on xcode: ["26.0", :build]
  # ScreenCaptureKit/AX/CGEvent parts run on macOS 15+; on-device STT
  # (SpeechAnalyzer) requires macOS 26 (Tahoe) at runtime.
  depends_on macos: :sequoia

  def install
    # Build only the CLI product — the package also contains the S1.app
    # target, and a GUI-target failure must never break `brew install s1`.
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "s1"
    bin.install ".build/release/s1"
  end

  def caveats
    <<~EOS
      s1 drives your Mac via Accessibility, Screen Recording, and Speech —
      macOS will prompt your terminal app for those permissions on first use.
      Run `s1 preflight` to see which grants are still missing.
      For the VLM/LLM policies you need an OpenAI-compatible endpoint,
      e.g. `brew install ollama && ollama pull gemma3:4b`.
    EOS
  end

  test do
    assert_match "OVERVIEW", shell_output("#{bin}/s1 --help")
  end
end
