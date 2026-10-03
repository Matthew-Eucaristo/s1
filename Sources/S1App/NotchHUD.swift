import AppKit
import SwiftUI
import S1Core

/// A borderless pill that drops from the camera-notch strip while s1 is
/// doing something — Apple's Dynamic-Island idiom for the Mac. There is no
/// public notch API: like every Mac notch app (boring.notch et al.) this is
/// a plain floating panel positioned between the auxiliary-top areas.
///
/// Cost model: the window only exists while s1 is listening or running —
/// idle hides *and releases* it, so the HUD's steady-state price is nil.
@available(macOS 26, *)
@MainActor
final class NotchHUDController {
    enum Phase: String { case listening, running }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// Show (or update) the pill for the given phase.
    func show(phase: Phase, detail: String) {
        hideTask?.cancel(); hideTask = nil
        let view = NotchHUDView(phase: phase, detail: detail)
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

    /// A result worth glancing at (done/failed) — flash it, then get out
    /// of the way. A later `show` cancels the pending hide.
    func flash(phase: Phase, detail: String, after seconds: Double = 2.0) {
        show(phase: phase, detail: detail)
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
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
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: .init(width: 280, height: 40)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        // Visible on every Space and over fullscreen apps — like Spotlight.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.hasShadow = false
        p.worksWhenModal = true
        p.contentView = NSHostingView(rootView: rootView)
        return p
    }

    /// Center horizontally in the notch gap (or mid-screen when the display
    /// has no notch), top edge tucked just under the menu-bar strip.
    static func position(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let size = panel.frame.size
        let cx: CGFloat
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            cx = (left.maxX + right.minX) / 2
        } else {
            cx = screen.frame.midX
        }
        let y = screen.visibleFrame.maxY - size.height - 6
        panel.setFrame(NSRect(x: cx - size.width / 2, y: y,
                              width: size.width, height: size.height),
                       display: false)
    }
}

@available(macOS 26, *)
struct NotchHUDView: View {
    let phase: NotchHUDController.Phase
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: phase == .listening ? "waveform" : "brain")
                .font(.callout.weight(.semibold))
                .symbolEffect(.pulse, isActive: true)
                .frame(width: 16)
            Text(phase == .listening ? "listening" : "working")
                .font(.callout.weight(.semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            Button {
                AppModel.shared.hudStopTapped()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.mini)
            .help(phase == .listening ? "Sleep the listener" : "Abort the run")
            .accessibilityLabel(phase == .listening ? "Sleep" : "Stop")
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .padding(.vertical, 7)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        // The pill speaks its own state — VoiceOver users get the same
        // "s1 is listening / working on step N" the sighted UI shows.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("s1 \(phase == .listening ? "listening" : "working")\(detail.isEmpty ? "" : ", \(detail)")")
    }
}
