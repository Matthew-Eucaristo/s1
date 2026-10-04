cask "s1" do
  version "0.2.0"
  sha256 "a223d6fd0a902196b8de6806181a5f1bb9113d7ba239ddddd63d7c5a1037a0bc"

  url "https://raw.githubusercontent.com/Matthew-Eucaristo/homebrew-tap/main/releases/v#{version}/S1-#{version}-app.zip"
  name "S1"
  desc "Voice-first agent — fast System 1 + LLM System 2, accessibility-driven"
  homepage "https://github.com/Matthew-Eucaristo/s1"

  depends_on macos: :tahoe

  app "S1.app"

  uninstall launchctl: "com.matthew.s1.serve",
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
    "~/Library/Preferences/com.matthew.s1.app.plist",
    "~/Library/Saved Application State/com.matthew.s1.app.savedState",
  ]

  caveats <<~EOS
    Ad-hoc signed → Gatekeeper will block the first open. Either install
    with `brew install --cask --no-quarantine s1`, or once:
      xattr -dr com.apple.quarantine /Applications/S1.app
    Then open S1 and grant Accessibility + Screen Recording + Microphone
    when it asks — `s1 preflight` (from `brew install s1`) shows the score.
  EOS
end
