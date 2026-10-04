# Homebrew formula for the s1 CLI — signed universal binary (arm64+x86_64).
#
# `brew install s1` drops the binary into brew's bin; `brew uninstall s1`
# removes every byte it installed. Run output lives in ~/.s1 — wipe it with
# `rm -rf ~/.s1` for a full reset.
class S1 < Formula
  desc "Voice-first agent — fast System 1 + LLM System 2, accessibility-driven"
  homepage "https://github.com/Matthew-Eucaristo/s1"
  url "https://raw.githubusercontent.com/Matthew-Eucaristo/homebrew-tap/main/releases/v0.2.0/s1-0.2.0-macos.tar.gz"
  sha256 "dee2921a68f851f12a5405c9bf1b51b546c70a224f76a9a955a51111706efac2"
  license "MIT"

  depends_on macos: :tahoe

  def install
    bin.install "s1"
  end

  def caveats
    <<~EOS
      s1 drives your Mac via Accessibility, Screen Recording, and Speech —
      macOS prompts your terminal app on first use; `s1 preflight` lists
      what's still missing.
      Menu-bar app + notch HUD:  brew install --cask s1
      Local model brain:         brew install ollama && ollama pull gemma3:4b
      Full reset:                brew uninstall s1 && rm -rf ~/.s1
    EOS
  end

  test do
    assert_match "OVERVIEW", shell_output("#{bin}/s1 --help")
  end
end
