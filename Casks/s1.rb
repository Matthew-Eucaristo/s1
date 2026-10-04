cask "s1" do
  version "0.2.0"
  sha256 "7d0bd4088c396e1d650f5729f672898856babe81935b2332aca020691934efa2"

  url "https://raw.githubusercontent.com/Matthew-Eucaristo/homebrew-tap/main/releases/v#{version}/S1-#{version}-app.zip"
  name "s1"
  desc "Voice-first agent — menu-bar companion (System 1 + System 2), CLI included"
  homepage "https://github.com/Matthew-Eucaristo/s1"

  depends_on macos: :tahoe

  app "S1.app"
  # The CLI ships inside the bundle (Contents/Resources/s1) — brew links it
  # into HOMEBREW_PREFIX/bin so `s1` works on PATH from the same install.
  binary "#{appdir}/S1.app/Contents/Resources/s1"

  uninstall launchctl: ["com.matthew.s1.serve", "sh.brew.s1"],
            quit:      "com.matthew.s1.app"

  # `brew uninstall --zap s1` — the one-command full wipe: app, grants-facing
  # bundle, and every byte of user state s1 ever wrote (config, run
  # artifacts, serve pid/state, screenshots).
  zap trash: [
    "~/.s1",
    "~/Library/Application Scripts/com.matthew.s1.app",
    "~/Library/Containers/com.matthew.s1.app",
    "~/Library/HTTPStorages/com.matthew.s1.app",
    "~/Library/LaunchAgents/com.matthew.s1.serve.plist",
    "~/Library/LaunchAgents/sh.brew.s1.plist",
    "~/Library/Preferences/com.matthew.s1.app.plist",
    "~/Library/Saved Application State/com.matthew.s1.app.savedState",
  ]

  caveats <<~EOS
    Ad-hoc signed → Gatekeeper will block the first open. Either install
    with `brew install --cask --no-quarantine s1`, or once:
      xattr -dr com.apple.quarantine /Applications/S1.app
    Then open S1 and grant Accessibility + Screen Recording + Microphone
    when it asks — `s1 preflight` shows the score.

      Always-on listener:        s1 serve --install   (launchd agent, armed at login)
      Local model brain:         brew install ollama && ollama pull gemma3:4b
      Full reset:                brew uninstall --cask s1 --zap
  EOS
end
