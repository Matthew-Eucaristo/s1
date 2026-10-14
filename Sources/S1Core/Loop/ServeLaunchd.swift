import Foundation

/// launchd packaging for `s1 serve --install` — the always-on daemon as a
/// real LaunchAgent: starts at login, respawns after a crash, and lets a
/// clean `s1 stop` stay stopped.
public enum ServeLaunchd {
    /// ~/Library/LaunchAgents identity.
    public static let label = "com.matthew.s1.serve"

    /// This process was started by the agent (launchd names the job).
    public static var runningAsAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    public static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    /// The plist as XML. Only crash exits respawn (SuccessfulExit false):
    /// `s1 stop`, Ctrl-C and `s1 serve --uninstall` are all clean exits and
    /// must stay authoritative — an always-on daemon must not zombie back
    /// the moment the user told it to die.
    /// The log, and the home the agent runs against: `S1Home.path`, so an
    /// `S1_HOME` install logs, locks and reads config where the installer
    /// looks (the variable is handed to the agent too).
    public static func plist(args: [String], home: String = S1Home.path,
                             env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;") }
        let argv = args.map { "        <string>\(esc($0))</string>" }.joined(separator: "\n")
        let log = esc(home + "/serve.log")
        let homeEnv = env["S1_HOME"].flatMap { $0.isEmpty ? nil : $0 }.map {
            "    <key>EnvironmentVariables</key> <dict><key>S1_HOME</key><string>\(esc($0))</string></dict>\n"
        } ?? ""
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
            <key>StandardOutPath</key>  <string>\(log)</string>
            <key>StandardErrorPath</key><string>\(log)</string>
        \(homeEnv)</dict>
        </plist>
        """
    }
}
