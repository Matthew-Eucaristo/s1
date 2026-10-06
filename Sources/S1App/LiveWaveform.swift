import SwiftUI
import S1Core

/// Live mic-level bars — the Siri-style "I can hear you" signal.
/// Renders the MicLevel ring buffer that the audio tap fills while a listen
/// turn is open. `TimelineView` ticks only while the view is onscreen and
/// `Canvas` redraws in one pass — the pair costs nothing the moment the
/// HUD or button area isn't visible.
@available(macOS 26, *)
struct LiveWaveform: View {
    /// Visible bars — recent samples right-aligned (newest at the right).
    var barCount: Int = 24
    var barWidth: CGFloat = 3
    var gap: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { _ in
            Canvas { ctx, size in
                let samples = MicLevel.shared.recent.suffix(barCount)
                let totalWidth = CGFloat(barCount) * (barWidth + gap) - gap
                let originX = size.width - totalWidth
                for (i, level) in samples.enumerated() {
                    let x = originX + CGFloat(i + (barCount - samples.count)) * (barWidth + gap)
                    let h = max(2, CGFloat(level) * size.height)
                    let rect = CGRect(x: x, y: (size.height - h) / 2,
                                      width: barWidth, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(AppModel.shared.accent))
                }
            }
        }
        // 0 levels = silence, which is also the honest "the mic hears
        // nothing" signal — flat ticks still tell Matthew the feature works.
        .accessibilityLabel("microphone level")
    }
}
