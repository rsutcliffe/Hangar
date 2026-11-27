import Charts
import SwiftUI

/// How much the orchestrator's runners have got through in six hours, and the latest runs that failed. Text from the state
/// file and from GitHub is always shown verbatim: never as Markdown, never as a link.
struct ThroughputCard: View {
    typealias Summary = OrchestratorState.Throughput

    let summary: Summary

    var body: some View {
        CollapsibleSection(.throughput, title: "Throughput · last 6 hours",
                           summary: .throughput(doneLastHour: summary.doneLastHour, failed6h: summary.failed6h), spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                tile("Done, last hour", number(summary.doneLastHour), help: "Jobs completed, whether they passed or failed")
                tile("Failed, 6 hours", number(summary.failed6h), help: "Workflow runs with a failed job, each counted once")
                tile("Running now", number(summary.runningNow), help: "The most jobs running at once in the newest five minutes")
                tile("Waiting now", number(summary.waitingNow), help: "The most jobs waiting at once in the newest five minutes")
                tile("Typical wait", summary.typicalWait ?? "—", help: "Today (UTC): each runner set's median wait, weighted by its runs")
            }
            Divider().overlay(Theme.line)
            chart("Jobs completed, per 5 minutes", \.completed, .bars, Theme.running)
            chart("Runs failed, per 5 minutes", \.failed, .bars, Theme.problem)
            chart("Jobs running, peak per 5 minutes", \.running, .step, Theme.running)
            chart("Jobs waiting, peak per 5 minutes", \.waiting, .line, Theme.running, showsTimes: true)
            if let total = summary.failureTotal { failureList(of: total) }
        }
    }

    private func number(_ n: Int?) -> String { n.map { $0.formatted() } ?? "—" }

    private func tile(_ title: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value == "—" ? "no data" : value)")
    }

    private func chart(_ title: String, _ value: KeyPath<Summary.Point, Int> & Sendable, _ style: SeriesChart.Style, _ color: Color,
                       showsTimes: Bool = false) -> some View {
        SeriesChart(title: title, points: summary.points, domain: summary.domain, value: value, style: style, color: color,
                    showsTimes: showsTimes)
    }

    private func failureList(of total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Theme.line).padding(.bottom, 4)
            HStack {
                Text("Recent failures").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                if total > 0 {
                    Text("latest \(summary.failures.count) of \(total)").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .help("The orchestrator keeps only its last 20 failed jobs, so this count can be below “Failed, 6 hours”. "
                              + "A run that first failed earlier is listed here but not counted there.")
                }
            }
            if total == 0 { Text("None in the last 6 hours").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, entry in row(entry) }
        }
    }

    private func row(_ entry: Summary.Entry) -> some View {
        let time = entry.time.map { Format.shortDateTime($0) } ?? "—"
        let more = entry.more > 0 ? "+\(entry.more) more in this run" : ""
        let said = [entry.repo, entry.job, entry.detail, more].filter { !$0.isEmpty }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
                .frame(width: 96, alignment: .leading)
            Text(verbatim: entry.repo).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.job).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(verbatim: entry.detail.isEmpty ? "—" : entry.detail).lineLimit(1).truncationMode(.tail)
                    // Never cut: a long step name gives way to it.
                    if !more.isEmpty { Text(more).foregroundStyle(Theme.muted).lineLimit(1).fixedSize() }
                }
                .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(Text(verbatim: said.joined(separator: " · ")))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([time] + said).joined(separator: ", ")))
    }
}

/// One series over the card's six hours, with its own axis from zero. Hovering names the bucket under the pointer.
private struct SeriesChart: View {
    enum Style { case bars, step, line }

    let title: String
    let points: [OrchestratorState.Throughput.Point]
    let domain: ClosedRange<Date>
    let value: KeyPath<OrchestratorState.Throughput.Point, Int> & Sendable
    let style: Style
    let color: Color
    let showsTimes: Bool
    @State private var hovered: Date?

    private static let plotHeight: CGFloat = 34
    private static let timesHeight: CGFloat = 16

    var body: some View {
        let peak = points.map { $0[keyPath: value] }.max()
        // Counts are whole, so the only ticks are zero and the peak; one when everything is zero.
        let top = max(1, peak ?? 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(hovered.map { OrchestratorState.hoverText(at: $0, points: points, value: value) }
                     ?? peak.map { "peak \($0.formatted())" } ?? "no data")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            Chart {
                ForEach(points, id: \.start) { p in marks(p) }
                if let hovered { RuleMark(x: .value("Time", hovered)).foregroundStyle(Theme.muted).lineStyle(StrokeStyle(lineWidth: 1)) }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...top)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine().foregroundStyle(Theme.line)
                    if showsTimes { AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.muted) }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, top]) { mark in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel {
                        // One width on every chart keeps the four time axes lined up.
                        Text((mark.as(Int.self) ?? 0).formatted(.number.notation(.compactName)))
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(Theme.muted)
                            .frame(width: 28, alignment: .leading)
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        guard case .active(let at) = phase, let frame = proxy.plotFrame else { hovered = nil; return }
                        let plot = geometry[frame]
                        // Compared, not made into a Range, which traps on a negative or non-finite width.
                        let x = at.x - plot.minX
                        hovered = x >= 0 && x < plot.width ? proxy.value(atX: x, as: Date.self) : nil
                    }
                }
            }
            .frame(height: Self.plotHeight + (showsTimes ? Self.timesHeight : 0))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OrchestratorState.spoken(title, points: points, value: value))
    }

    @ChartContentBuilder private func marks(_ p: OrchestratorState.Throughput.Point) -> some ChartContent {
        let n = p[keyPath: value]
        let length = OrchestratorState.bucketLength
        switch style {
        case .bars:
            // A minute's gap keeps neighbouring bars apart.
            RectangleMark(xStart: .value("From", p.start.addingTimeInterval(30)), xEnd: .value("To", p.start.addingTimeInterval(length - 30)),
                          yStart: .value("Zero", 0), yEnd: .value(title, n))
                .foregroundStyle(color)
        case .step:
            // Each bucket is drawn flat from its start to its end, so one on its own still shows.
            ForEach([p.start, p.start.addingTimeInterval(length)], id: \.self) { time in
                LineMark(x: .value("Time", time), y: .value(title, n), series: .value("Stretch", p.segment))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        case .line:
            let middle = p.start.addingTimeInterval(length / 2)
            LineMark(x: .value("Time", middle), y: .value(title, n), series: .value("Stretch", p.segment))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            // A line needs two points: a bucket with no neighbour is a dot.
            if points.lazy.filter({ $0.segment == p.segment }).prefix(2).count == 1 {
                PointMark(x: .value("Time", middle), y: .value(title, n)).foregroundStyle(color).symbolSize(12)
            }
        }
    }
}
