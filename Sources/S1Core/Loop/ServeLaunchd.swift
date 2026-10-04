import Foundation

/// launchd packaging for `s1 serve --install` — the always-on daemon as a
/// real LaunchAgent: starts at login, respawns after a crash, and lets a
/// clean `s1 stop` stay stopped.
public enum ServeLaunchd {
    /// ~/Library/LaunchAgents identity.
    public static let label = "com.matthew.s1.serve"
    public static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    /// The plist as XML. Only crash exits respawn (SuccessfulExit false):
    /// `s1 stop`, Ctrl-C and `s1 serve --uninstall` are all clean exits and
    /// must stay authoritative — an always-on daemon must not zombie back
    /// the moment the user told it to die.
    public static func plist(args: [String]) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;") }
        let argv = args.map { "        <string>\(esc($0))</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>            <string>\(label)</string>
            <key>ProgramArguments</key> <array>
        \(argv)
            </array>
            <key>RunAtLoad</key>        <true/>
            <key>KeepAlive</key>        <dict><key>SuccessfulExit</key><false/></dict>
            <key>ProcessType</key>      <string>Interactive</string>
            <key>StandardOutPath</key>  <string>\(NSHomeDirectory())/.s1/serve.log</string>
            <key>StandardErrorPath</key><string>\(NSHomeDirectory())/.s1/serve.log</string>
        </dict>
        </plist>
        """
    }
}
