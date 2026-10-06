import AppKit
import SwiftUI
import S1Core

/// A glass pill that drops from the camera-notch strip while s1 is doing
/// something — the Dynamic Island idiom on the Mac. There's no public notch
/// API, so like every Mac notch app it's a floating panel positioned
/// between the auxiliary top areas (or top-center on displays without one).
///
/// Cost model: the window only exists while s1 is listening or working —
/// idle hides *and releases* it, so the HUD's steady-state price is nil.
@available(macOS 26, *)
@MainActor
final class NotchHUDController {
    enum Content: Equatable {
        case listening(String)
        case working(String)
        case finished(Turn.State, String)
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ content: Content) {
        hideTask?.cancel(); hideTask = nil
        let view = NotchHUDView(content: content)
        if let hosting = panel?.contentView as? NSHostingView<NotchHUDView> {
            hosting.rootView = view
        } else {
            panel = Self.makePanel(rootView: view)
        }
        guard let panel else { return }
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        Self.position(panel)
        panel.orderFrontRegardless()
    }

    /// An outcome worth a glance — show it, then get out of the way.
    func flash(_ content: Content, for seconds: Double = 2.4) {
        show(content)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel(); hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func makePanel(rootView: NotchHUDView) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        // Every Space, over fullscreen apps — like Spotlight.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.hasShadow = false
        p.worksWhenModal = true
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        return p
    }

    /// Centered on the notch gap, tucked just under the menu bar.
    static func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let cx: CGFloat = if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            (l.maxX + r.minX) / 2
        } else {
            screen.frame.midX
        }
        let y = screen.visibleFrame.maxY - size.height - 6
        panel.setFrame(NSRect(x: cx - size.width / 2, y: y, width: size.width, height: size.height),
                       display: true)
    }
}

@available(macOS 26, *)
struct NotchHUDView: View {
    let content: NotchHUDController.Content

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            if case .listening = content {
                LiveWaveform(barCount: 14, barWidth: 2.5, gap: 2)
                    .frame(width: 52, height: 18)
                    .accessibilityHidden(true)
            }
            if !isFinished {
                Button {
                    AppModel.shared.hudStopTapped()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(isListening ? "Stop listening" : "Stop")
                .accessibilityLabel(isListening ? "Stop listening" : "Stop")
            }
        }
        .padding(.leading, 12).padding(.trailing, isFinished ? 14 : 7)
        .padding(.vertical, 7)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .padding(4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("s1, \(title)\(detail.isEmpty ? "" : ", \(detail)")")
    }

    private var isListening: Bool { if case .listening = content { return true }; return false }
    private var isFinished: Bool { if case .finished = content { return true }; return false }

    @ViewBuilder
    private var leading: some View {
        switch content {
        case .listening:
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, isActive: true)
        case .working:
            ProgressView().controlSize(.small)
        case .finished(let state, _):
            Image(systemName: state.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.tint)
                .symbolEffect(.bounce, value: true)
        }
    }

    private var title: String {
        switch content {
        case .listening: String(localized: "Listening")
        case .working: String(localized: "Working")
        case .finished(let state, _): state.labelText
        }
    }

    private var detail: String {
        switch content {
        case .listening(let t): t
        case .working(let t): t
        case .finished(_, let r): r
        }
    }
}
