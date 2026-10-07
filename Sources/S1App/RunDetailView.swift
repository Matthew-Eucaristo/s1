import ImageIO
import SwiftUI
import S1Core

/// A past run, read back from its evidence: what was asked, every step
/// with who decided it and why, and the screenshots it took.
struct RunDetailView: View {
    let run: RunSummary
    let model: AppModel
    @State private var steps: [StepRecord] = []
    @State private var shots: [URL] = []

    var body: some View {
        let state = Turn.State(status: run.status)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(run.goal)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 14) {
                        Label { state.label } icon: {
                            Image(systemName: state.symbol).foregroundStyle(state.tint)
                        }
                        if let d = run.started {
                            Text(d, format: .dateTime.weekday(.wide).hour().minute())
                        }
                        if let s = run.started, let f = run.finished {
                            Text(StepPresentation.duration(f.timeIntervalSince(s)))
                        }
                        Text("\(steps.count) steps")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if let s = run.summary, !s.isEmpty, run.ok {
                        Text(s)
                            .padding(.top, 4)
                            .textSelection(.enabled)
                    }
                }

                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                            StepDetail(step: step)
                            if i < steps.count - 1 { Divider().padding(.leading, 38) }
                        }
                    }
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 14, style: .continuous))
                }

                if !shots.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Screenshots").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                            ForEach(shots, id: \.self) { url in
                                Thumbnail(url: url)
                                    .onTapGesture { NSWorkspace.shared.open(url) }
                                    .help(url.lastPathComponent)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(run.goal)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.revealRunDir(run.dir.path) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show this run's evidence in Finder")
                Button { model.runAgain(run.goal) } label: {
                    Label("Run Again", systemImage: "arrow.clockwise")
                }
                .help("Run this command again")
                .disabled(model.running)
            }
        }
        .task(id: run.dir) {
            let dir = run.dir
            (steps, shots) = await Task.detached {
                ((try? RunReader.steps(in: dir)) ?? [], RunHistory.screenshots(in: dir))
            }.value
        }
    }
}

/// A step you can open: rationale, confidence, the gate's verdict, and
/// the model's raw reply when there was one.
private struct StepDetail: View {
    let step: StepRecord
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 0) {
                    StepRow(step: step, compact: !open)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .padding(.leading, 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if open {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Decided by", step.decidedBy)
                    if let c = step.confidence { row("Confidence", c.formatted(.number.precision(.fractionLength(2)))) }
                    if let r = step.rationale, !r.isEmpty { row("Why", r) }
                    row("Safety gate", step.gate)
                    if let e = step.escalation { row("Escalated", "\(e.to) — \(e.reason)") }
                    if let m = step.modelReply, !m.isEmpty { row("Model reply", m, mono: true) }
                }
                .font(.caption)
                .padding(.leading, 28)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func row(_ label: LocalizedStringKey, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .lineLimit(8)
        }
    }
}

/// Downsampled off the main thread — run screenshots are full-resolution PNGs.
private struct Thumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .task(id: url) {
            let u = url
            image = await Task.detached { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                ] as CFDictionary)
            }.value
        }
    }
}
