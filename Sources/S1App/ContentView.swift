import SwiftUI
import S1Core

/// The main window: history in the sidebar, the live conversation (or a
/// past run) in the detail. Glass is reserved for the navigation layer —
/// toolbar, sidebar, composer, banners; content uses plain fills so a long
/// run never stacks dozens of material layers.
struct ContentView: View {
    enum Item: Hashable {
        case conversation
        case run(URL)
    }

    @Bindable var model: AppModel
    @State private var selection: Item? = .conversation
    @State private var history: [RunSummary] = []
    @State private var search = ""
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .navigationTitle("s1")
        .navigationSubtitle(subtitle)
        .tint(model.accent)
        .toolbar { toolbar }
        .task(id: model.historyRevision) { await loadHistory() }
        .onAppear {
            model.openSettingsAction = { openSettings() }
            if model.needsOnboarding { openWindow(id: "onboarding") }
        }
        .onChange(of: model.needsOnboarding) {
            if model.needsOnboarding { openWindow(id: "onboarding") }
        }
        // A new command always brings the conversation forward.
        .onChange(of: model.turns.count) { selection = .conversation }
        .onChange(of: model.focusGoalToken) { selection = .conversation }
    }

    // MARK: - sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label {
                HStack {
                    Text("Conversation")
                    Spacer()
                    if model.currentTurn != nil {
                        ProgressView().controlSize(.mini)
                    }
                }
            } icon: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .tag(Item.conversation)

            ForEach(groups, id: \.id) { group in
                Section(group.title) {
                    ForEach(group.runs) { run in
                        HistoryRow(run: run)
                            .tag(Item.run(run.dir))
                            .contextMenu {
                                Button("Run Again") { model.runAgain(run.goal) }
                                Button("Copy Command") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(run.goal, forType: .string)
                                }
                                Divider()
                                Button("Show in Finder") { model.revealRunDir(run.dir.path) }
                            }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search history")
        .overlay {
            if !search.isEmpty && groups.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private struct Group { let id: Int; let title: LocalizedStringKey; let runs: [RunSummary] }

    private var groups: [Group] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let runs = q.isEmpty ? history : history.filter { $0.goal.localizedCaseInsensitiveContains(q) }
        let cal = Calendar.current
        var today: [RunSummary] = [], yesterday: [RunSummary] = [], week: [RunSummary] = [], earlier: [RunSummary] = []
        for r in runs {
            guard let d = r.started else { earlier.append(r); continue }
            if cal.isDateInToday(d) { today.append(r) }
            else if cal.isDateInYesterday(d) { yesterday.append(r) }
            else if d > Date().addingTimeInterval(-7 * 86_400) { week.append(r) }
            else { earlier.append(r) }
        }
        return [Group(id: 0, title: "Today", runs: today), Group(id: 1, title: "Yesterday", runs: yesterday),
                Group(id: 2, title: "Previous 7 Days", runs: week), Group(id: 3, title: "Earlier", runs: earlier)]
            .filter { !$0.runs.isEmpty }
    }

    private func loadHistory() async {
        history = DemoContent.enabled ? DemoContent.history() : await Task.detached { RunHistory.list() }.value
        if case .run(let url)? = selection, !history.contains(where: { $0.dir == url }) {
            selection = .conversation
        }
    }

    // MARK: - detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .run(let url)?:
            if let run = history.first(where: { $0.dir == url }) {
                RunDetailView(run: run, model: model)
                    .id(url)
            } else {
                ConversationView(model: model)
            }
        default:
            ConversationView(model: model)
        }
    }

    // MARK: - toolbar

    private var subtitle: String {
        if !model.companionAvailable { return String(localized: "Companion off — a terminal listener is active") }
        switch model.serveState {
        case .listening: return String(localized: "Listening…")
        case .running: return String(localized: "Working…")
        case .idle: return model.running ? String(localized: "Working…") : String(localized: "Press ⇧⇧ anywhere to talk")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                selection = .conversation
                model.clearConversation()
                model.focusGoalToken += 1
            } label: {
                Label("New Conversation", systemImage: "square.and.pencil")
            }
            .help("New Conversation (⌘K)")
            .disabled(model.running || model.turns.isEmpty)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            let on = model.serveState != .idle
            Button {
                model.toggleServe()
            } label: {
                Label(on ? "Stop Listening" : "Listen", systemImage: on ? "waveform" : "mic")
                    .symbolEffect(.variableColor.iterative, isActive: model.serveState == .listening)
            }
            .tint(on ? .red : nil)
            .buttonStyle(on ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.automatic))
            .help(on ? "Stop listening (⇧⇧)" : "Listen for commands (⇧⇧ or ⌃⌥Space, anywhere)")
            .disabled(!model.companionAvailable)
        }
    }
}

/// Type-erased button style so one toolbar button can switch looks.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct HistoryRow: View {
    let run: RunSummary

    var body: some View {
        let state = Turn.State(status: run.status)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: state.symbol)
                .font(.caption)
                .foregroundStyle(state.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.goal).lineLimit(2)
                if let d = run.started {
                    Text(d, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - conversation

struct ConversationView: View {
    @Bindable var model: AppModel
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(model.turns) { turn in
                    TurnView(turn: turn, model: model)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: model.turns.count)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .overlay {
            if model.turns.isEmpty {
                EmptyConversation(model: model) { composerFocused = true }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.permissions.accessibility && !DemoContent.enabled { AccessibilityBanner(model: model) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Composer(model: model, focused: $composerFocused)
        }
        .onAppear { composerFocused = true }
        .onChange(of: model.focusGoalToken) { composerFocused = true }
    }
}

private struct TurnView: View {
    let turn: Turn
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 90)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if turn.spoken {
                        Image(systemName: "waveform")
                            .font(.caption.weight(.semibold))
                            .accessibilityLabel("spoken")
                    }
                    Text(turn.goal).textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(model.onAccent)
                .background(model.accent.gradient, in: .rect(cornerRadius: 18, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(turn.goal)")

            if !turn.steps.isEmpty || turn.state == .running {
                ActivityCard(turn: turn, model: model)
            }

            if let reply = turn.reply {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: turn.state.symbol)
                        .foregroundStyle(turn.state.tint)
                        .symbolEffect(.bounce, value: turn.state)
                    Text(reply)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The agent's work for one turn — open while it runs, folded to one line
/// when it's done (click to see every step again).
private struct ActivityCard: View {
    let turn: Turn
    let model: AppModel
    @State private var expanded: Bool?

    private var isOpen: Bool { expanded ?? (turn.state == .running) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { expanded = !isOpen }
            } label: {
                HStack(spacing: 10) {
                    if turn.state == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundStyle(.secondary)
                    }
                    Text(header)
                        .font(.callout)
                        .foregroundStyle(turn.state == .running ? .primary : .secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer()
                    if !turn.steps.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(turn.steps.isEmpty)

            if isOpen && !turn.steps.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                        StepRow(step: step)
                    }
                }
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 14, style: .continuous))
        .contextMenu {
            if let dir = turn.runDir {
                Button("Show in Finder") { model.revealRunDir(dir) }
            }
            Button("Run Again") { model.runAgain(turn.goal) }
        }
    }

    private var header: String {
        if turn.state == .running {
            if let p = turn.phase { return p }
            if let last = turn.steps.last { return StepPresentation(last).title }
            return String(localized: "Working…")
        }
        let n = turn.steps.count
        let steps = String(localized: "\(n) steps")
        guard let d = turn.duration else { return steps }
        return "\(steps) · \(StepPresentation.duration(d))"
    }
}

// MARK: - composer

private struct Composer: View {
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding
    @Namespace private var glass

    private var canSend: Bool { !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 10) {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            GlassEffectContainer(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    Button {
                        model.toggleListen()
                    } label: {
                        Image(systemName: model.listening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .contentShape(.circle)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive().tint(model.listening ? .red.opacity(0.55) : nil), in: .circle)
                    .help("Speak a command (⌘L)")
                    .accessibilityLabel(model.listening ? "Stop listening" : "Speak a command")

                    VStack(alignment: .leading, spacing: 4) {
                        if model.listening {
                            HStack(spacing: 8) {
                                LiveWaveform(barCount: 18).frame(width: 64, height: 16)
                                Text(model.transcript.isEmpty ? String(localized: "Listening…") : model.transcript)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .font(.callout)
                            .transition(.opacity)
                        }
                        TextField("Ask s1 to do something…", text: $model.goal, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .lineLimit(1...6)
                            .focused(focused)
                            .onSubmit { Task { await model.run() } }
                            .onKeyPress(.upArrow) {
                                guard model.goal.isEmpty, let last = model.recentGoals.first else { return .ignored }
                                model.goal = last
                                return .handled
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 38)
                    .glassEffect(.regular, in: .rect(cornerRadius: 19, style: .continuous))

                    if model.running {
                        Button { model.stop() } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 38, height: 38)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive().tint(.red.opacity(0.6)), in: .circle)
                        .glassEffectID("action", in: glass)
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop (⌘.)")
                        .accessibilityLabel("Stop")
                    } else {
                        Button { Task { await model.run() } } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 38, height: 38)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(canSend ? model.onAccent : .secondary)
                        .glassEffect(.regular.interactive().tint(canSend ? model.accent : nil), in: .circle)
                        .glassEffectID("action", in: glass)
                        .disabled(!canSend)
                        .help("Run (↩)")
                        .accessibilityLabel("Run")
                    }
                }
            }
            .animation(.smooth(duration: 0.3), value: model.running)
            .animation(.smooth(duration: 0.25), value: model.listening)
        }
        .animation(.smooth, value: model.notice)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 8)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - empty state + banners

private struct EmptyConversation: View {
    @Bindable var model: AppModel
    var focusComposer: () -> Void

    private var examples: [String] {
        SpokenLanguage.code(SpokenLanguage.candidates(for: model.locale)[0]) == "id"
            ? ["buka Notes", "buka TextEdit lalu ketik halo", "tangkap layar", "ingat bahwa editorku Zed"]
            : ["open Notes", "open TextEdit then type hello", "take a screenshot", "remember that my editor is Zed"]
    }

    /// Recent commands first, then examples; one chip per command.
    private var suggestions: [String] {
        var seen = Set<String>()
        return (model.recentGoals.prefix(3) + examples)
            .filter { seen.insert($0.lowercased().trimmingCharacters(in: .punctuationCharacters)).inserted }
            .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("What should s1 do?")
                    .font(.title.weight(.semibold))
                Text("Type it below — or press ⇧⇧ anywhere on your Mac and say it.")
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { ex in
                    Button(ex) {
                        model.goal = ex
                        focusComposer()
                    }
                    .buttonStyle(.glass)
                }
            }
            .frame(maxWidth: 520)
            if !model.models.hasReasoner {
                Button {
                    model.openSettings("models")
                } label: {
                    Label("Only the built-in grammar is on. Connect a model to handle anything else.",
                          systemImage: "sparkles")
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.accent)
                .font(.callout)
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

private struct AccessibilityBanner: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("s1 needs Accessibility access")
                    .font(.callout.weight(.semibold))
                Text("It's how s1 sees and uses your Mac. Already on? Click Repair to refresh it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Repair") { model.resetAccessibility() }
            Button("Open Settings") { model.requestPermissions() }
                .buttonStyle(.glassProminent)
        }
        .controlSize(.small)
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .frame(maxWidth: 820)
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? s.width : s.width + spacing
            if rows[rows.count - 1].width + extra > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let r = rows.count - 1
            rows[r].width += rows[r].indices.isEmpty ? s.width : s.width + spacing
            rows[r].height = max(rows[r].height, s.height)
            rows[r].indices.append(i)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
