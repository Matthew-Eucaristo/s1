import AppKit
import Carbon.HIToolbox
import SwiftUI
import S1Core

/// ⌥Space launcher — a Spotlight-style floating panel. Carbon hotkey (no
/// Input Monitoring grant needed), non-activating panel so the app you were
/// in stays frontmost and paste / window moves land there.
@available(macOS 26, *)
@MainActor
final class LauncherController: NSObject, NSWindowDelegate {
    static let shared = LauncherController()

    let state = LauncherState()
    private var panel: LauncherPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var dictationRef: EventHotKeyRef?
    private var clipTask: Task<Void, Never>?
    private var lastChange = NSPasteboard.general.changeCount
    private var ownChange = -1

    func install() {
        guard hotKeyRef == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let which = hk.id
            Task { @MainActor in
                switch (which, pressed) {
                case (1, true): LauncherController.shared.toggle()
                case (2, true): AppModel.shared.dictationKeyDown()
                case (2, false): AppModel.shared.dictationKeyUp()
                default: break
                }
            }
            return noErr
        }, 2, &specs, nil, nil)
        let sig = OSType(0x7331_6C63 /* s1lc */)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: sig, id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        // ⌃⌥D dictation: hold to talk, or tap to start and let VAD end it.
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), EventHotKeyID(signature: sig, id: 2),
                            GetApplicationEventTarget(), 0, &dictationRef)
        startClipboardWatch()
    }

    func toggle() { panel?.isVisible == true ? hide() : show() }

    func show() {
        state.previousApp = NSWorkspace.shared.frontmostApplication
        state.apps = Launcher.installedApps()
        state.snippets = Snippets.load()
        state.recents = AppModel.shared.recentGoals
        state.query = ""; state.selection = 0; state.files = []
        if state.rates == nil { state.rates = FX.cached() }
        if FX.isStale(state.rates) {
            Task { if let r = await FX.refresh() { self.state.rates = r } }
        }
        let p = panel ?? makePanel()
        panel = p
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - 340, y: f.maxY - f.height * 0.18))
        }
        p.makeKeyAndOrderFront(nil)
        state.focusToken += 1
    }

    func hide() { panel?.orderOut(nil) }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func makePanel() -> LauncherPanel {
        let p = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                              styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.delegate = self
        let host = NSHostingView(rootView: LauncherView(state: state) { [weak self] in self?.perform($0) })
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        return p
    }

    // MARK: actions

    func perform(_ item: LauncherItem?) {
        guard let item else { hide(); return }
        let target = state.previousApp
        hide()
        switch item.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.payload),
                                               configuration: .init())
        case .snippet:
            paste(Snippets.expand(item.payload, clipboard: NSPasteboard.general.string(forType: .string)),
                  restore: true, into: target)
        case .file: NSWorkspace.shared.open(URL(fileURLWithPath: item.payload))
        case .spotlight: NSWorkspace.shared.showSearchResults(forQueryString: item.payload)
        case .web:
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: item.payload)]
            if let u = c.url { NSWorkspace.shared.open(u) }
        case .clip: paste(item.payload, restore: false, into: target)
        case .calc: setClipboard(item.payload)
        case .window:
            if let l = WindowLayout(rawValue: item.payload), let pid = target?.processIdentifier {
                _ = WindowOps.apply(l, pid: pid)
            }
        case .recent, .ask:
            AppModel.shared.goal = item.payload
            Task { await AppModel.shared.run() }
        case .command:
            AppModel.shared.openSettings("snippets")
        }
    }

    private func setClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(s, forType: .string)
        ownChange = pb.changeCount
    }

    /// Paste into the app you came from; snippets put your clipboard back.
    func paste(_ text: String, restore: Bool, into app: NSRunningApplication?) {
        let pb = NSPasteboard.general
        let previous = restore ? pb.string(forType: .string) : nil
        setClipboard(text)
        let mine = pb.changeCount
        Task { @MainActor in
            app?.activate()
            try? await Task.sleep(for: .milliseconds(120))
            _ = try? await CGEventActuator().perform(.keyCombo(keys: ["cmd", "v"]), frontmostPID: nil)
            guard restore, let previous else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if pb.changeCount == mine { self.setClipboard(previous) }
        }
    }

    /// Clipboard history: in memory only (never written to disk), skips
    /// password-manager items, capped at 50.
    private func startClipboardWatch() {
        clipTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self else { return }
                let pb = NSPasteboard.general
                guard pb.changeCount != self.lastChange else { continue }
                self.lastChange = pb.changeCount
                guard pb.changeCount != self.ownChange else { continue }
                let types = pb.types?.map(\.rawValue) ?? []
                let text = pb.string(forType: .string)
                guard ClipboardPolicy.shouldRecord(types: types, text: text), let text else { continue }
                self.state.clips.removeAll { $0 == text }
                self.state.clips.insert(text, at: 0)
                if self.state.clips.count > 50 { self.state.clips.removeLast() }
            }
        }
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@available(macOS 26, *)
@Observable
@MainActor
final class LauncherState {
    var query = ""
    var selection = 0
    var focusToken = 0
    var apps: [(name: String, path: String)] = []
    var snippets: [Snippet] = []
    var clips: [String] = []
    var recents: [String] = []
    var previousApp: NSRunningApplication?
    var files: [String] = []
    var rates: FX.Rates?
    private var fileTask: Task<Void, Never>?

    var items: [LauncherItem] {
        Launcher.search(query, apps: apps, snippets: snippets, clips: clips, recents: recents,
                        files: files, rates: rates)
    }

    /// Debounced Spotlight-index lookup; stale results never overwrite newer ones.
    func searchFiles() {
        fileTask?.cancel()
        let q = query
        files = []
        guard q.count >= 2, Calc.evaluate(q) == nil, Convert.item(q, rates: rates) == nil else { return }
        fileTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await FileSearch.search(q)
            guard !Task.isCancelled, self.query == q else { return }
            self.files = found
        }
    }
}

@available(macOS 26, *)
struct LauncherView: View {
    @Bindable var state: LauncherState
    let perform: (LauncherItem?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let items = state.items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Search apps, files, snippets, 100 usd to idr — or ask s1…", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { perform(items.indices.contains(state.selection) ? items[state.selection] : items.last) }
                    .onChange(of: state.query) { state.selection = 0; state.searchFiles() }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == state.selection)
                                .id(i)
                                .onTapGesture { perform(item) }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: state.selection) { proxy.scrollTo(state.selection) }
            }
            .frame(height: min(340, CGFloat(items.count) * 50 + 16))
        }
        .frame(width: 680)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onKeyPress(.downArrow) { state.selection = min(state.selection + 1, items.count - 1); return .handled }
        .onKeyPress(.upArrow) { state.selection = max(state.selection - 1, 0); return .handled }
        .onKeyPress(.escape) { perform(nil); return .handled }
        .onChange(of: state.focusToken, initial: true) { focused = true }
    }

    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            icon(item)
                .frame(width: 26, height: 26)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if selected { Text("↩").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? AppModel.shared.accent.opacity(0.22) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }

    @ViewBuilder private func icon(_ item: LauncherItem) -> some View {
        switch item.kind {
        case .app: Image(nsImage: NSWorkspace.shared.icon(forFile: item.payload)).resizable()
        case .snippet: Image(systemName: "text.badge.plus")
        case .clip: Image(systemName: "doc.on.clipboard")
        case .calc: Image(systemName: "equal.circle")
        case .window: Image(systemName: "rectangle.split.2x1")
        case .recent: Image(systemName: "clock.arrow.circlepath")
        case .ask: Image(systemName: "sparkles").foregroundStyle(.tint)
        case .command: Image(systemName: "pencil")
        case .file: Image(nsImage: NSWorkspace.shared.icon(forFile: item.payload)).resizable()
        case .spotlight: Image(systemName: "magnifyingglass.circle")
        case .web: Image(systemName: "globe")
        }
    }
}
