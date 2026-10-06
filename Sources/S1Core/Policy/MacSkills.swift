import Foundation
import IOKit.ps

/// What a Mac can do, as instant System 1 skills: every System Settings pane,
/// the standard folders, the system shortcuts (Mission Control, Spotlight,
/// emoji, screenshots, brightness…) and quick answers (time, date, battery).
/// No model: a phrase maps straight to an action. The Reasoner gets the same
/// list (`guide`) so it hands these to System 1 as plain steps.
public enum MacSkills {
    /// System Settings panes: spoken names → extension ID (macOS 13+, read
    /// from /System/Library/ExtensionKit on macOS 27).
    static let panes: [(names: [String], id: String)] = [
        (["wi-fi", "wifi", "wireless"], "com.apple.wifi-settings-extension"),
        (["bluetooth"], "com.apple.BluetoothSettings"),
        (["network", "jaringan"], "com.apple.Network-Settings.extension"),
        (["vpn"], "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"),
        (["battery", "baterai", "power", "energy"], "com.apple.Battery-Settings.extension"),
        (["general", "umum"], "com.apple.systempreferences.GeneralSettings"),
        (["about", "about this mac", "tentang"], "com.apple.SystemProfiler.AboutExtension"),
        (["software update", "update", "pembaruan", "pembaruan perangkat lunak"], "com.apple.Software-Update-Settings.extension"),
        (["storage", "penyimpanan"], "com.apple.settings.Storage"),
        (["airdrop", "handoff", "airdrop & handoff"], "com.apple.AirDrop-Handoff-Settings.extension"),
        (["login items", "startup apps", "item login"], "com.apple.LoginItems-Settings.extension"),
        (["language", "region", "language & region", "bahasa", "wilayah"], "com.apple.Localization-Settings.extension"),
        (["date", "time", "date & time", "tanggal", "waktu"], "com.apple.Date-Time-Settings.extension"),
        (["sharing", "berbagi"], "com.apple.Sharing-Settings.extension"),
        (["time machine", "backup", "cadangan"], "com.apple.Time-Machine-Settings.extension"),
        (["transfer or reset", "reset", "erase"], "com.apple.Transfer-Reset-Settings.extension"),
        (["startup disk"], "com.apple.Startup-Disk-Settings.extension"),
        (["accessibility", "aksesibilitas"], "com.apple.Accessibility-Settings.extension"),
        (["appearance", "dark mode", "light mode", "tampilan", "mode gelap"], "com.apple.Appearance-Settings.extension"),
        (["control center", "pusat kontrol", "menu bar"], "com.apple.ControlCenter-Settings.extension"),
        (["desktop & dock", "dock", "desktop and dock", "mission control"], "com.apple.Desktop-Settings.extension"),
        (["displays", "display", "monitor", "layar", "night shift"], "com.apple.Displays-Settings.extension"),
        (["wallpaper", "background", "latar"], "com.apple.Wallpaper-Settings.extension"),
        (["lock screen", "layar kunci", "screen saver"], "com.apple.Lock-Screen-Settings.extension"),
        (["siri", "apple intelligence"], "com.apple.Siri-Settings.extension"),
        (["spotlight"], "com.apple.Spotlight-Settings.extension"),
        (["notifications", "notification", "notifikasi"], "com.apple.Notifications-Settings.extension"),
        (["sound", "audio", "suara", "volume"], "com.apple.Sound-Settings.extension"),
        (["focus", "do not disturb", "fokus", "jangan ganggu"], "com.apple.Focus-Settings.extension"),
        (["screen time", "waktu layar"], "com.apple.Screen-Time-Settings.extension"),
        (["privacy", "security", "privacy & security", "privasi", "keamanan"], "com.apple.settings.PrivacySecurity.extension"),
        (["touch id", "password", "touch id & password", "kata sandi"], "com.apple.Touch-ID-Settings.extension"),
        (["users", "groups", "users & groups", "pengguna"], "com.apple.Users-Groups-Settings.extension"),
        (["apple account", "apple id", "icloud", "akun apple"], "com.apple.systempreferences.AppleIDSettings"),
        (["family", "keluarga"], "com.apple.Family-Settings.extension"),
        (["internet accounts", "accounts", "akun internet"], "com.apple.Internet-Accounts-Settings.extension"),
        (["wallet", "apple pay"], "com.apple.WalletSettingsExtension"),
        (["game center"], "com.apple.Game-Center-Settings.extension"),
        (["game controllers", "controller"], "com.apple.Game-Controller-Settings.extension"),
        (["keyboard", "keyboard shortcuts", "papan ketik", "keyboard settings"], "com.apple.Keyboard-Settings.extension"),
        (["trackpad"], "com.apple.Trackpad-Settings.extension"),
        (["mouse", "tetikus"], "com.apple.Mouse-Settings.extension"),
        (["printers", "printer", "scanners", "printers & scanners", "pencetak"], "com.apple.Print-Scan-Settings.extension"),
        (["headphones", "airpods", "headphone"], "com.apple.HeadphoneSettings"),
        (["profiles", "device management"], "com.apple.Profiles-Settings.extension"),
    ]

    /// Standard folders: spoken names → path under the home folder.
    static let folders: [(names: [String], path: String)] = [
        (["downloads", "unduhan", "download"], "Downloads"),
        (["documents", "dokumen"], "Documents"),
        (["desktop"], "Desktop"),
        (["pictures", "gambar", "foto"], "Pictures"),
        (["music", "musik"], "Music"),
        (["movies", "videos", "film", "video"], "Movies"),
        (["home", "rumah", "home folder"], ""),
        (["applications", "aplikasi"], "/Applications"),
        (["icloud drive", "icloud"], "Library/Mobile Documents/com~apple~CloudDocs"),
    ]
    /// Folders whose name alone means the folder ("open downloads"); the rest
    /// need the word "folder" ("open music folder" — "open Music" is the app).
    static let plainFolders: Set<String> = ["downloads", "unduhan", "documents", "dokumen", "desktop", "applications", "aplikasi", "icloud drive"]

    /// System actions by their everyday names.
    static let system: [(phrases: [String], keys: [String], label: String)] = [
        (["mission control", "show all windows", "tampilkan semua jendela", "semua jendela"], ["ctrl", "up"], "Mission Control"),
        (["app windows", "app expose", "application windows", "jendela aplikasi"], ["ctrl", "down"], "App Exposé"),
        (["show desktop", "tampilkan desktop", "lihat desktop"], ["f11"], "Show Desktop"),
        (["spotlight", "open spotlight", "search my mac", "cari di mac"], ["cmd", "space"], "Spotlight"),
        (["emoji", "emoji picker", "emoji keyboard", "open emoji", "pilih emoji", "emoji and symbols"], ["ctrl", "cmd", "space"], "Emoji & Symbols"),
        (["force quit", "force quit menu", "paksa keluar", "paksa berhenti"], ["cmd", "opt", "esc"], "Force Quit"),
        (["screenshot area", "screenshot selection", "capture area", "tangkap area", "screenshot sebagian"], ["cmd", "shift", "4"], "Screenshot of an area"),
        (["screen recording", "record screen", "record the screen", "rekam layar", "screenshot options", "screenshot toolbar"], ["cmd", "shift", "5"], "Screenshot toolbar"),
        (["brightness up", "brighter", "naikkan kecerahan", "terangkan layar", "layar lebih terang"], ["brightnessup"], "Brightness up"),
        (["brightness down", "dimmer", "dim the screen", "turunkan kecerahan", "redupkan layar", "layar lebih redup"], ["brightnessdown"], "Brightness down"),
        (["keyboard light up", "keyboard brightness up", "naikkan lampu keyboard"], ["illuminationup"], "Keyboard light up"),
        (["keyboard light down", "keyboard brightness down", "turunkan lampu keyboard"], ["illuminationdown"], "Keyboard light down"),
        (["switch keyboard language", "next input source", "ganti bahasa keyboard", "ganti input"], ["ctrl", "space"], "Next input source"),
        (["show hidden files", "tampilkan file tersembunyi"], ["cmd", "shift", "period"], "Show hidden files"),
        (["go to folder", "pergi ke folder"], ["cmd", "shift", "g"], "Go to Folder"),
        (["reopen closed tab", "undo close tab", "buka lagi tab yang ditutup"], ["cmd", "shift", "t"], "Reopen closed tab"),
    ]

    static let verbs = ["open ", "buka ", "show ", "tampilkan ", "go to ", "pergi ke ", "launch ", "lihat ", "please ", "tolong "]
    static let settingsWords = ["system settings", "system preferences", "settings", "setting", "preferences",
                                "preference", "pengaturan", "setelan", "preferensi"]

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[.!?,"“”]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func stripVerbs(_ s: String) -> String {
        var t = s, changed = true
        while changed {
            changed = false
            for v in verbs where t.hasPrefix(v) { t = String(t.dropFirst(v.count)); changed = true }
            for w in ["the ", "my "] where t.hasPrefix(w) { t = String(t.dropFirst(w.count)); changed = true }
        }
        return t
    }

    /// The Mac skill a spoken phrase asks for ("buka pengaturan wifi",
    /// "mission control", "open downloads"), with a label for the log.
    public static func match(_ phrase: String) -> (action: Action, label: String)? {
        let p = normalize(phrase), bare = stripVerbs(p)
        if let s = system.first(where: { $0.phrases.contains(p) || $0.phrases.contains(bare) }) {
            return (.keyCombo(keys: s.keys), s.label)
        }
        // Settings: "<pane> settings", "pengaturan <pane>", "settings <pane>".
        if let w = settingsWords.first(where: { bare.contains($0) }) {
            let rest = bare.replacingOccurrences(of: w, with: " ")
                .replacingOccurrences(of: #"\b(for|di|untuk|system|sistem)\b"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return (.openApp(name: "System Settings"), "System Settings") }
            if let pane = panes.first(where: { $0.names.contains(rest) })
                ?? panes.first(where: { $0.names.contains { rest.contains($0) && $0.count >= 4 } }) {
                return (.openURL("x-apple.systempreferences:\(pane.id)"), "\(pane.names[0].capitalized) settings")
            }
            return nil
        }
        // Folders: "open downloads", "buka folder dokumen", "open music folder".
        var name = bare, saidFolder = false
        for w in ["folder ", " folder"] where name.contains(w) {
            name = name.replacingOccurrences(of: w, with: " ").trimmingCharacters(in: .whitespaces); saidFolder = true
        }
        if name == "folder" { return nil }
        if let f = folders.first(where: { $0.names.contains(name) }), saidFolder || plainFolders.contains(name) {
            let path = f.path.hasPrefix("/") ? f.path : (NSHomeDirectory() as NSString).appendingPathComponent(f.path)
            return (.openURL(URL(fileURLWithPath: path).absoluteString), "\(f.names[0].capitalized) folder")
        }
        return nil
    }

    /// Quick facts System 1 answers itself: the time, the date, the battery.
    public static func answer(_ goal: String, now: Date = Date()) -> String? {
        let g = normalize(goal)
        let time = ["what time is it", "whats the time", "what's the time", "jam berapa", "jam berapa sekarang", "sekarang jam berapa"]
        let date = ["whats the date", "what's the date", "what day is it", "what's today's date", "tanggal berapa",
                    "hari apa", "hari ini tanggal berapa", "sekarang tanggal berapa"]
        let battery = ["battery", "battery level", "how much battery", "whats my battery", "what's my battery",
                       "baterai", "baterai berapa", "sisa baterai", "berapa baterai"]
        if time.contains(g) { return now.formatted(date: .omitted, time: .shortened) + "." }
        if date.contains(g) { return now.formatted(date: .complete, time: .omitted) + "." }
        if battery.contains(g) { return batteryStatus() }
        return nil
    }

    static func batteryStatus() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let pct = Int((Double(cur) / Double(max) * 100).rounded())
            let charging = (d[kIOPSIsChargingKey] as? Bool) == true
            return "Battery \(pct)%" + (charging ? ", charging." : ".")
        }
        return "This Mac has no battery."
    }

    /// One paragraph for the Reasoner: what System 1 can do instantly.
    public static var guide: String {
        let paneNames = panes.map { $0.names[0] }.joined(separator: ", ")
        let actions = system.map { $0.phrases[0] }.joined(separator: ", ")
        return """
        Mac skills System 1 runs instantly — delegate them as plain goals: \
        "open <pane> settings" (\(paneNames)); "open <folder>" (downloads, documents, \
        desktop folder, pictures folder, applications, icloud drive); \(actions); \
        lock screen, volume up/down, mute, play/pause; "what time is it", "battery".
        """
    }
}
