# Homebrew cask for the S1 menu-bar app.
#
# Lives in the tap repo Matthew-Eucaristo/homebrew-tap as Casks/s1.rb.
# scripts/publish-tap.sh regenerates it with real version + sha256 on
# every release — do not hand-edit values here.
cask "s1" do
  version "0.2.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # filled at release

  url "https://github.com/Matthew-Eucaristo/s1/releases/download/v#{version}/S1-#{version}-app.zip"
  name "S1"
  desc "Voice-first macOS agent — menu-bar companion (System 1 + System 2)"
  homepage "https://github.com/Matthew-Eucaristo/s1"

  # ScreenCaptureKit/AX/CGEvent need macOS 15+; on-device STT wants 26.
  depends_on macos: ">= :sequoia"

  app "S1.app"

  # `brew uninstall --cask s1`        -> quits the app + removes /Applications/S1.app
  # `brew uninstall --cask s1 --zap`  -> also removes every trace below
  uninstall quit: "com.matthew.s1.app"

  zap trash: [
    "~/.s1",                                                   # config, pid locks, run artifacts, screenshots
    "~/Library/Application Scripts/com.matthew.s1.app",
    "~/Library/Containers/com.matthew.s1.app",
    "~/Library/HTTPStorages/com.matthew.s1.app",
    "~/Library/Preferences/com.matthew.s1.app.plist",
    "~/Library/Saved Application State/com.matthew.s1.app.savedState",
  ]

  caveats <<~EOS
    First launch asks for Accessibility, Screen Recording, and (for voice)
    Microphone — System Settings prompts; `s1 preflight` lists any gaps.
    Builds ship self-signed (not notarized): if Gatekeeper blocks the first
    launch, `brew reinstall --cask s1 --no-quarantine` or
    `xattr -dr com.apple.quarantine /Applications/S1.app`.
  EOS
end
