import Charts
import S1Core
import SwiftUI

/// Settings → Usage: what the models did and what it cost. Numbers only,
/// from ~/.s1/usage.jsonl; prices are what the provider billed, else the
/// public list price, else plan / free / unknown — and always labelled so.
@available(macOS 26, *)
struct UsageSettings: View {
    enum Period: String, CaseIterable, Identifiable {
        case day, week, month
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self { case .day: "24 Hours"; case .week: "7 Days"; case .month: "30 Days" }
        }
        var seconds: TimeInterval {
            switch self { case .day: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400 }
        }
        var bucket: Calendar.Component { self == .day ? .hour : .day }
    }
    enum Metric: String, CaseIterable, Identifiable {
        case cost, tokens, calls
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self { case .cost: "Cost"; case .tokens: "Tokens"; case .calls: "Calls" }
        }
    }

    @AppStorage("usagePeriod") private var period: Period = .week
    @AppStorage("usageMetric") private var metric: Metric = .cost
    @State private var report = UsageReport()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                tiles
                chart
                models

                FootNote("Billed: the provider reported the charge. Est.: tokens × the public list price (OpenRouter's catalog, refreshed daily). Plan: a subscription, nothing per call. Local and :free models cost nothing. Full log: `s1 usage`.")
            }
            .padding(20)
        }
        .task(id: period) { await load() }
    }

    // MARK: - tiles

    private var tiles: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Tile(title: "Spent", value: Self.usd(report.spentUSD),
                     detail: report.estimatedUSD > 0
                        ? "\(Self.usd(report.billedUSD)) billed · \(Self.usd(report.estimatedUSD)) est."
                        : report.planCalls > 0 ? "\(report.planCalls) calls in plan" : "billed by providers")
                Tile(title: "Calls", value: report.calls.formatted(),
                     detail: report.failures > 0 ? "\(report.failures) failed" : "all succeeded")
                Tile(title: "Tokens", value: Self.compact(report.input + report.output),
                     detail: "\(Self.compact(report.input)) in · \(Self.compact(report.output)) out")
                Tile(title: "Cache", value: report.cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                     detail: "\(Self.compact(report.cached)) read · \(Self.compact(report.cacheWrite)) write")
            }
        }
    }

    // MARK: - chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(period == .day ? "By hour" : "By day").font(.headline)
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if report.buckets.isEmpty {
                Text(loaded ? "No model calls in this period." : "Loading…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(report.buckets, id: \.self) { b in
                    BarMark(x: .value("Time", b.start, unit: period.bucket),
                            y: .value(metric.rawValue, value(b)))
                        .foregroundStyle(by: .value("Role", Self.roleName(b.role)))
                }
                .chartForegroundStyleScale(domain: Self.roleOrder.map(Self.roleName),
                                           range: Self.roleColors)
                .chartXAxis {
                    if period == .day {
                        AxisMarks(values: .stride(by: .hour, count: 6)) {
                            AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
                        }
                    } else {
                        AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 5)) {
                            AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        }
                    }
                }
                .chartXScale(domain: Date().addingTimeInterval(-period.seconds)...Date())
                .overlay {
                    if metric == .cost, report.spentUSD == 0 {
                        Text(report.planCalls + report.freeCalls > 0
                             ? "Nothing billed: every call was in a plan or free."
                             : "No priced calls in this period.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.background.opacity(0.8), in: .capsule)
                    }
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(metric == .cost ? Self.usd(d) : Self.compact(Int(d))) }
                        }
                    }
                }
                .frame(height: 170)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private func value(_ b: UsageReport.Bucket) -> Double {
        switch metric {
        case .cost: b.usd
        case .tokens: Double(b.tokens)
        case .calls: Double(b.calls)
        }
    }

    // MARK: - per model

    private var models: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By model").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(report.rows.enumerated()), id: \.element) { i, r in
                    if i > 0 { Divider() }
                    ModelUsageRow(row: r)
                }
                if report.rows.isEmpty {
                    Text("No model calls in this period.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - data

    private func load() async {
        let since = Date().addingTimeInterval(-period.seconds)
        let bucket = period.bucket
        report = await Task.detached {
            UsageReport.build(UsageLog.load(since: since), prices: Pricing.table(), bucket: bucket)
        }.value
        loaded = true
        // Fresh list prices (at most daily), then re-price.
        await Pricing.refreshIfStale()
        report = await Task.detached {
            UsageReport.build(UsageLog.load(since: since), prices: Pricing.table(), bucket: bucket)
        }.value
    }

    // MARK: - formatting

    static let roleOrder = ["judge", "reasoner", "search", "transcribe", "speak"]
    static let roleColors: [Color] = [.gray, .orange, .teal, .blue, .green]

    static func roleName(_ role: String) -> String {
        if role == "search" { return String(localized: "Web search") }
        return ModelRole(rawValue: role).map { $0.short } ?? role.capitalized
    }

    static func usd(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v < 0.01 { return String(format: "$%.4f", v) }
        return v.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func compact(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }
}

@available(macOS 26, *)
private struct Tile: View {
    let title: LocalizedStringKey
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

@available(macOS 26, *)
private struct ModelUsageRow: View {
    let row: UsageReport.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.model).lineLimit(1).truncationMode(.middle)
                Text("\(UsageSettings.roleName(row.role)) · \(row.host)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Text(costText).monospacedDigit()
                    BillingBadge(billing: row.billing)
                }
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var costText: String {
        switch row.billing {
        case .plan: String(localized: "In plan")
        case .free: String(localized: "Free")
        case .unknown: "—"
        case .billed, .estimated: UsageSettings.usd(row.usd)
        }
    }

    private var detail: String {
        var s = "\(row.calls) calls · \(UsageSettings.compact(row.input)) in"
        if row.cached > 0 { s += " (\(UsageSettings.compact(row.cached)) cached)" }
        if row.cacheWrite > 0 { s += " · \(UsageSettings.compact(row.cacheWrite)) cache write" }
        s += " · \(UsageSettings.compact(row.output)) out · \(row.avgMs) ms"
        if row.failures > 0 { s += " · \(row.failures) failed" }
        return s
    }
}

@available(macOS 26, *)
private struct BillingBadge: View {
    let billing: Billing

    var body: some View {
        if let label {
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(billing == .billed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background(billing == .billed ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary),
                            in: .capsule)
        }
    }

    private var label: LocalizedStringKey? {
        switch billing {
        case .billed: "Billed"
        case .estimated: "Est."
        default: nil
        }
    }
}
