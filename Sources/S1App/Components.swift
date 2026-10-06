import SwiftUI
import S1Core

// MARK: - steps

/// How a logged step reads in the UI: a symbol and a plain-language line,
/// never the raw action enum.
struct StepPresentation {
    let symbol: String
    let title: String
    let detail: String?
    /// "S1" / "S2" / nil for system steps.
    let brain: String?
    let escalation: String?
    let verified: Bool?
    let confidence: Double?

    init(_ rec: StepRecord) {
        (symbol, title) = Self.describe(rec.action)
        detail = rec.outcome
        brain = rec.decidedBy.hasPrefix("s2") ? "S2" : rec.decidedBy.hasPrefix("s1") ? "S1" : nil
        escalation = rec.escalation.map { "\($0.to): \($0.reason)" }
        verified = rec.verified
        confidence = rec.confidence
    }

    static func describe(_ action: Action?) -> (String, String) {
        guard let action else { return ("questionmark.circle", String(localized: "No action")) }
        switch action {
        case .openApp(let n): return ("app.badge", String(localized: "Open \(n)"))
        case .typeText(let t): return ("keyboard", String(localized: "Type “\(t)”"))
        case .editText(let f, let r):
            return r.isEmpty
                ? ("delete.left", String(localized: "Delete “\(f)”"))
                : ("pencil.line", String(localized: "Replace “\(f)” with “\(r)”"))
        case .keyCombo(let k): return ("command", String(localized: "Press \(keyLabel(k))"))
        case .click(let x, let y): return ("cursorarrow.click", String(localized: "Click at \(Int(x)), \(Int(y))"))
        case .rightClick(let x, let y): return ("contextualmenu.and.cursorarrow", String(localized: "Right-click at \(Int(x)), \(Int(y))"))
        case .doubleClick(let x, let y): return ("cursorarrow.click.2", String(localized: "Double-click at \(Int(x)), \(Int(y))"))
        case .drag: return ("hand.draw", String(localized: "Drag"))
        case .moveMouse: return ("cursorarrow.motionlines", String(localized: "Move the pointer"))
        case .scroll(_, let dy): return ("scroll", dy < 0 ? String(localized: "Scroll up") : String(localized: "Scroll down"))
        case .axPress(let r): return ("hand.tap", String(localized: "Press \(element(r))"))
        case .axSetValue(let r, let v): return ("character.cursor.ibeam", String(localized: "Fill \(element(r)) with “\(v)”"))
        case .axAction(let r, let n): return ("hand.tap", "\(n.replacingOccurrences(of: "AX", with: "")) \(element(r))")
        case .axSetAttribute(let r, let a, _): return ("slider.horizontal.3", String(localized: "Set \(a.replacingOccurrences(of: "AX", with: "")) on \(element(r))"))
        case .wait(let s): return ("hourglass", String(localized: "Wait \(s.formatted())s"))
        case .captureScreenshot: return ("camera.viewfinder", String(localized: "Look at the screen"))
        case .verify(let e): return ("checkmark.circle", String(localized: "Check for “\(e)”"))
        case .done: return ("flag.checkered", String(localized: "Finish"))
        case .shell(let c): return ("terminal", String(localized: "Run \(c)"))
        case .custom(let n, _): return ("puzzlepiece.extension", n)
        }
    }

    /// "0.4 s", "3.1 s", "2 min 5 s" — runs are usually seconds long.
    static func duration(_ t: TimeInterval) -> String {
        t < 60
            ? Measurement(value: (t * 10).rounded() / 10, unit: UnitDuration.seconds)
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0...1))))
            : Duration.seconds(t).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    /// ["cmd","shift","s"] → "⌘⇧S".
    static func keyLabel(_ keys: [String]) -> String {
        let map = ["cmd": "⌘", "command": "⌘", "shift": "⇧", "alt": "⌥", "option": "⌥", "opt": "⌥",
                   "ctrl": "⌃", "control": "⌃", "return": "↩", "enter": "↩", "tab": "⇥", "esc": "⎋",
                   "escape": "⎋", "space": "Space", "delete": "⌫", "backspace": "⌫", "up": "↑",
                   "down": "↓", "left": "←", "right": "→", "fn": "fn"]
        return keys.map { map[$0.lowercased()] ?? $0.uppercased() }.joined()
    }

    /// AX refs carry role + label; show the label people read on screen.
    private static func element(_ ref: String) -> String {
        if let q = ref.firstIndex(where: { $0 == "'" || $0 == "\"" || $0 == "“" }) {
            let rest = ref[ref.index(after: q)...]
            if let end = rest.firstIndex(where: { $0 == "'" || $0 == "\"" || $0 == "”" }) {
                return "“\(rest[..<end])”"
            }
        }
        return ref
    }
}

/// One step as a compact row — the conversation's activity cards and the
/// history detail both use it.
@available(macOS 26, *)
struct StepRow: View {
    let step: StepRecord
    var compact = true

    var body: some View {
        let p = StepPresentation(step)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: p.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title)
                    .font(.callout)
                    .lineLimit(compact ? 1 : 3)
                if let d = p.detail, !d.isEmpty, !compact || d.count < 80 {
                    Text(d)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 4)
                }
            }
            Spacer(minLength: 8)
            if let esc = p.escalation {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .help(esc)
                    .accessibilityLabel("escalated")
            }
            if let b = p.brain {
                BrainTag(text: b)
                    .help(p.confidence.map { "\(b) · confidence \($0.formatted(.number.precision(.fractionLength(2))))" } ?? b)
            }
            if let v = p.verified {
                Image(systemName: v ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(v ? .green : .red)
                    .accessibilityLabel(v ? "verified" : "verification failed")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "S1" (grammar or Judge) in neutral grey, "S2" (Reasoner) in the accent.
struct BrainTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundStyle(text == "S2" ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(text == "S2" ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary), in: .capsule)
    }
}

// MARK: - turn states

extension Turn.State {
    var symbol: String {
        switch self {
        case .running: "circle.dotted"
        case .done: "checkmark.circle.fill"
        case .needsYou: "hand.raised.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .stopped: "stop.circle.fill"
        }
    }

    @available(macOS 26, *) @MainActor
    var tint: Color {
        switch self {
        case .running: AppModel.shared.accent
        case .done: .green
        case .needsYou: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    var labelText: String {
        switch self {
        case .running: String(localized: "Working")
        case .done: String(localized: "Done")
        case .needsYou: String(localized: "Needs you")
        case .failed: String(localized: "Didn't finish")
        case .stopped: String(localized: "Stopped")
        }
    }

    var label: Text { Text(labelText) }

    /// History rows only know the stored status string.
    init(status: String?) {
        switch status.flatMap(RunStatus.init(rawValue:)) {
        case .done?: self = .done
        case .needsHuman?: self = .needsYou
        case .aborted?: self = .stopped
        case nil: self = .stopped
        default: self = .failed
        }
    }
}

// MARK: - providers

/// A provider's badge: its official mark in white on a brand-coloured
/// rounded square — the System Settings idiom. Custom servers get a symbol.
struct ProviderBadge: View {
    let template: ProviderTemplate
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(template.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                if let logo = ProviderLogo.image(template.id) {
                    Image(nsImage: logo)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .padding(size * 0.2)
                } else {
                    Image(systemName: template.symbol ?? "server.rack")
                        .font(.system(size: size * 0.46, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// A small filled dot for live state.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .symbolEffect(.pulse, isActive: pulsing)
            .accessibilityHidden(true)
    }
}

/// Keyboard shortcut rendered as key caps: ⌃ ⌥ Space.
struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: .rect(cornerRadius: 5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// Section footer text, leading-aligned like System Settings.
struct FootNote: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }
    var body: some View {
        Text(key)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - accent

/// The app's accent: s1 orange (the website's colour) by default, or the
/// accent chosen in System Settings → Appearance.
enum AccentChoice: String, CaseIterable, Identifiable {
    case s1, system
    var id: String { rawValue }
}

enum Theme {
    /// Signal orange, a touch deeper in light mode for contrast.
    static let orange = Color(nsColor: NSColor(name: "s1Orange") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.17, alpha: 1)
            : NSColor(srgbRed: 0.90, green: 0.33, blue: 0.10, alpha: 1)
    })
    /// Text on an orange fill — near-black reads better than white on orange.
    static let ink = Color(red: 0.07, green: 0.07, blue: 0.08)
}
