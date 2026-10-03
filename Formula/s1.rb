# Homebrew formula for the s1 CLI — installs the prebuilt universal binary.
#
# Lives in the tap repo Matthew-Eucaristo/homebrew-tap as Formula/s1.rb.
# scripts/publish-tap.sh regenerates it with real version + sha256 on
# every release — do not hand-edit values here.
#
# A binary formula, deliberately: `brew install s1` drops the signed
# arm64+x86_64 binary into brew's bin — no Xcode/Swift toolchain needed
# and `brew uninstall` leaves zero residue. (homebrew-core would require
# a source build; our own tap gets to choose the friendlier option.)
class S1 < Formula
  desc "Voice-first macOS agent — fast System 1 + LLM System 2, accessibility-driven"
  homepage "https://github.com/Matthew-Eucaristo/s1"
  license "MIT"
  version "0.2.0"
  url "https://github.com/Matthew-Eucaristo/s1/releases/download/v#{version}/s1-#{version}-macos.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # filled at release

  # The binary is signed (stable TCC identity); Gatekeeper may still want a
  # one-time `xattr -dr com.apple.quarantine` until we ship Developer ID.
  depends_on macos: :sequoia

  def install
    bin.install "s1"
  end

  def caveats
    <<~EOS
      s1 drives your Mac via Accessibility, Screen Recording, and Speech —
      macOS prompts your terminal app on first use; `s1 preflight` lists
      what's still missing.
      Menu-bar companion:  brew install --cask s1
      Local model brain:   brew install ollama && ollama pull gemma3:4b
    EOS
  end

  test do
    assert_match "OVERVIEW", shell_output("#{bin}/s1 --help")
  end
end
