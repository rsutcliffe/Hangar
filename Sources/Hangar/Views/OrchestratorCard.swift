import SwiftUI

/// What the runner orchestrator reports about itself, from its state file. Text from the file is always shown verbatim:
/// never as Markdown, never as a link.
struct OrchestratorCard: View {
    struct Row: Equatable {
        var host: String
        var text: String
        var age: String
    }

    enum Part: Equatable {
        case notReporting(String)
        case needsUpdate
        case noProblems
        case problems([Row])
        case recommendations([String])
        case events(inLast24h: Int?, [Row])
        case typicalWait(String)
    }

    let parts: [Part]

    /// The card's contents from top to bottom; empty when there is no card (no state, and none ever seen).
    nonisolated static func sections(state: OrchestratorState?, seen: Bool, otherVersion: Bool, now: Date) -> [Part] {
        func age(_ date: Date?) -> String { date.map { Format.duration(now.timeIntervalSince($0)) } ?? "" }
        guard let state, !state.isStale(now: now) else {
            if otherVersion { return [.needsUpdate] }
            if let state { return [.notReporting("Last heartbeat \(age(state.heartbeat)) ago")] }
            return seen ? [.notReporting("No heartbeat read since Hangar started")] : []
        }
        let problems = (state.problems ?? []).map { Row(host: $0.host ?? "", text: $0.text ?? $0.class ?? "Unnamed problem", age: age($0.since)) }
        var parts: [Part] = [problems.isEmpty ? .noProblems : .problems(problems)]
        let advice = (state.recommendations ?? []).compactMap(\.text)
        if !advice.isEmpty { parts.append(.recommendations(advice)) }
        // The file lists events newest last; the card shows the newest first.
        let events = (state.events ?? []).suffix(5).reversed().map { Row(host: $0.host ?? "", text: $0.text ?? $0.kind ?? "Event", age: age($0.time)) }
        if !events.isEmpty || state.eventsTotal24h != nil { parts.append(.events(inLast24h: state.eventsTotal24h, events)) }
        if let line = waitLine(days: state.days, now: now) { parts.append(.typicalWait(line)) }
        return parts
    }

    /// "Typical wait" is the runs-weighted mean of each set's `waitP50Sec`, so it is not a median of all jobs. Days are UTC
    /// dates. nil with nothing for today; no comparison with nothing in the 7 days before.
    nonisolated static func waitLine(days: [OrchestratorState.Day]?, now: Date) -> String? {
        let today = utcDay(now), weekAgo = utcDay(now.addingTimeInterval(-7 * 86_400))
        guard let now = typicalWait(days: days, include: { $0 == today }) else { return nil }
        let before = typicalWait(days: days) { $0 >= weekAgo && $0 < today }
        return "Typical wait today \(now)" + (before.map { ", previous 7 days \($0)" } ?? "")
    }

    /// A date as the file names its days.
    nonisolated static func utcDay(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }

    /// The runs-weighted mean wait over the days `include` accepts, as text; nil when none of them has a run.
    nonisolated static func typicalWait(days: [OrchestratorState.Day]?, include: (String) -> Bool) -> String? {
        var runs = 0.0, total = 0.0                 // Double: numbers from a file must not be able to overflow
        for d in days ?? [] where d.date.map(include) == true {
            for set in (d.sets ?? [:]).values {
                guard let n = set.runs, n > 0, let wait = set.waitP50Sec else { continue }
                runs += Double(n); total += Double(n) * Double(wait)
            }
        }
        guard runs > 0 else { return nil }
        let seconds = Int(min(1e9, max(0, (total / runs).rounded())))
        if seconds < 60 { return "\(seconds)s" }
        if seconds >= 3600 { return Format.duration(TimeInterval(seconds)) }
        return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Orchestrator").font(.system(size: 12, weight: .semibold)).padding(.bottom, 6)
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Divider().overlay(Theme.line)
                section(part).padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    @ViewBuilder private func section(_ part: Part) -> some View {
        switch part {
        case .notReporting(let detail):
            VStack(alignment: .leading, spacing: 2) {
                Text("Orchestrator not reporting").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.problemText)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        case .needsUpdate:
            Text("Hangar needs updating to read the orchestrator's state").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.problemText)
        case .noProblems:
            Text("No problems").font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .problems(let rows):
            list(rows, color: Theme.problemText)
        case .recommendations(let advice):
            VStack(alignment: .leading, spacing: 4) {
                heading("Recommendations")
                ForEach(Array(advice.enumerated()), id: \.offset) { _, text in wrapped(text) }
            }
        case .events(let total, let rows):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    heading("Recent events")
                    Spacer()
                    if let total { Text("\(total) in the last 24 hours").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted) }
                }
                list(rows, color: Theme.text)
            }
        case .typicalWait(let line):
            Text(line).font(.system(size: 12)).monospacedDigit()
        }
    }

    /// Rows of host, text and age. A row with no host gives the text the whole width.
    private func list(_ rows: [Row], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if !row.host.isEmpty {
                        Text(verbatim: row.host).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            .frame(width: 130, alignment: .leading)
                    }
                    wrapped(row.text).foregroundStyle(color)
                    Text(row.age).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
    }

    /// File text wraps inside the card's width. Eight lines hold the 300 characters the writer cuts it to, and stop a longer
    /// one from taking over the window.
    private func wrapped(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).lineLimit(8).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).help(Text(verbatim: text))
    }
}
