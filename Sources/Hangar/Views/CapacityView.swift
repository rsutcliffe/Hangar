import SwiftUI

/// Last 24 hours of how busy each runner was and how long the queue got. Opened from Window > Capacity.
struct CapacityView: View {
    var store: MonitorStore

    var body: some View {
        ScrollView(.vertical) { content }
            .frame(width: 560)
            .frame(minHeight: 420, idealHeight: 720, maxHeight: 820)
            .foregroundStyle(Theme.text)
    }

    private var content: some View {
        let hours = store.utilisation.recent(count: 24, now: Date())
        let rows = Self.split(store.utilisation.runnerIDs.filter { Self.lastSeen($0, hours: hours) != nil }, hours: hours)
        let groups = store.utilisation.onDemandGroups.filter { g in hours.contains { $0.bucket?.onDemand?[g] != nil } }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Capacity · last 24 hours").font(.system(size: 13, weight: .semibold))
            if hours.allSatisfy({ $0.bucket == nil }) {
                Text("Nothing recorded yet. Hangar records one reading per poll and keeps 8 days.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                onDemandSection(groups, hours: hours)
                if !rows.current.isEmpty {
                    sectionTitle("Runners on your Macs", note: "A thin line: seen, not busy. Blank: no reading.")
                    ForEach(rows.current, id: \.self) { runnerRow($0, hours: hours, lastSeen: nil) }
                }
                if !rows.past.isEmpty {
                    sectionTitle("Past runners", note: "Not seen in the latest recorded hours. Each figure covers only the hours shown beside it.")
                    ForEach(rows.past, id: \.self) { runnerRow($0, hours: hours, lastSeen: Self.lastSeen($0, hours: hours)) }
                }
                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Queue").font(.system(size: 12, weight: .semibold))
                    Text(Self.queueSummary(hours, format: { Format.shortDateTime($0) }))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    let peak = max(1, hours.compactMap { $0.bucket?.peakQueue }.max() ?? 1)
                    HourBars(values: hours.map { $0.bucket.map { Double($0.peakQueue) / Double(peak) } }, color: Theme.problem)
                }
                HStack {
                    Text("24 h ago").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("now").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }
            failuresSection
        }
        .padding(20)
        .accessibilityElement(children: .contain)
    }

    private func sectionTitle(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Divider().overlay(Theme.line).padding(.bottom, 6)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(note).font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func onDemandSection(_ groups: [String], hours: [(hour: Date, bucket: HourBucket?)]) -> some View {
        // One scale for every group, so bar heights can be compared between them.
        let top = max(1, groups.flatMap { g in hours.compactMap { UtilisationLog.onDemandAverage($0.bucket, group: g) } }.max() ?? 1)
        sectionTitle("On-demand runners",
                     note: groups.isEmpty ? "No on-demand jobs recorded. Hangar counts them from version 0.1.21, while it is open."
                                          : "Average jobs running in each hour, by Mac and job queue. A full bar is \(String(format: "%.1f", top)) jobs.")
        ForEach(groups, id: \.self) { group in
            VStack(alignment: .leading, spacing: 4) {
                Text(group).font(.system(size: 12, weight: .semibold))
                Text(Self.onDemandSummary(hours.map(\.bucket), group: group)).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                HourBars(values: hours.map { UtilisationLog.onDemandAverage($0.bucket, group: group).map { $0 / top } }, color: Theme.running)
            }
        }
    }

    private func runnerRow(_ id: String, hours: [(hour: Date, bucket: HourBucket?)], lastSeen: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(id).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(Self.summary(hours: hours.map(\.bucket), runner: id) + (lastSeen.map { " · last in the hour from " + Format.shortDateTime($0) } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
            }
            HourBars(values: hours.map { UtilisationLog.busyFraction($0.bucket, runner: id) }, color: Theme.running)
        }
    }

    /// The latest recorded failures with the step that failed; each row opens the job on GitHub.
    private var failuresSection: some View {
        let recent = store.failures.recent(8)
        return VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.line)
            Text("Recent failures").font(.system(size: 12, weight: .semibold))
            if recent.isEmpty {
                Text("None recorded yet.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else {
                ForEach(recent) { f in
                    JobLink(url: f.url.flatMap(GitHubLink.safe)) {
                        HStack(spacing: 8) {
                            Text(Format.shortDateTime(f.at)).frame(width: 110, alignment: .leading).foregroundStyle(Theme.muted)
                                .help(Format.duration(Date().timeIntervalSince(f.at)) + " ago")
                            Text(f.runner).fontWeight(.semibold).frame(width: 110, alignment: .leading)
                            Text("\(f.title) · \(f.reason)").foregroundStyle(Theme.problemText).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11)).monospacedDigit()
                    }
                }
            }
        }
    }

    /// Runners seen in the latest recorded hour or the one before it, and the rest. Judged from the history, not from the clock,
    /// so a Mac that had Hangar closed overnight does not move every runner to the past.
    static func split(_ ids: [String], hours: [(hour: Date, bucket: HourBucket?)]) -> (current: [String], past: [String]) {
        let latest = hours.lastIndex { !($0.bucket?.total.isEmpty ?? true) } ?? 0
        let recent = hours[max(0, latest - 1)...latest]
        let current = ids.filter { id in recent.contains { $0.bucket?.total[id] != nil } }
        return (current, ids.filter { !current.contains($0) })
    }

    static func lastSeen(_ id: String, hours: [(hour: Date, bucket: HourBucket?)]) -> Date? {
        hours.last { $0.bucket?.total[id] != nil }?.hour
    }

    static func onDemandSummary(_ hours: [HourBucket?], group: String) -> String {
        let counted = hours.compactMap { $0 }.filter { ($0.onDemandPolls ?? 0) > 0 }
        let polls = counted.compactMap(\.onDemandPolls).reduce(0, +)
        guard polls > 0 else { return "not recorded" }
        let sum = counted.compactMap { $0.onDemand?[group]?.sum }.reduce(0, +)
        let peak = counted.compactMap { $0.onDemand?[group]?.peak }.max() ?? 0
        return "average \(String(format: "%.1f", Double(sum) / Double(polls))) running · peak \(peak) · recorded in \(counted.count) of \(hours.count) hours"
    }

    /// "62% busy" over the hours the runner was observed, and how many hours those were.
    static func summary(hours: [HourBucket?], runner: String) -> String {
        let seen = hours.compactMap { $0 }.compactMap { b -> (Int, Int)? in b.total[runner].map { (b.busy[runner] ?? 0, $0) } }
        let total = seen.map(\.1).reduce(0, +)
        guard total > 0 else { return "not seen" }
        return "\(Int((Double(seen.map(\.0).reduce(0, +)) / Double(total) * 100).rounded()))% busy · seen in \(seen.count) of \(hours.count) hours"
    }

    /// The peak and the longest wait, saying when the wait was and, where recorded, which job it was.
    static func queueSummary(_ hours: [(hour: Date, bucket: HourBucket?)], format: (Date) -> String) -> String {
        let peak = hours.compactMap { $0.bucket?.peakQueue }.max() ?? 0
        let worst = hours.compactMap { h in h.bucket.map { (hour: h.hour, bucket: $0) } }.max { $0.bucket.longestWaitSeconds < $1.bucket.longestWaitSeconds }
        let wait = worst?.bucket.longestWaitSeconds ?? 0
        var text = "peak \(peak) queued · longest wait \(Format.duration(TimeInterval(wait)))"
        if let worst, wait > 0 {
            if let at = worst.bucket.longestWaitAt {
                text += " (\(worst.bucket.longestWaitJob.map { $0 + ", " } ?? "")\(format(at)))"
            } else {
                text += " (in the hour from \(format(worst.hour)))"
            }
        }
        return text
    }
}

private struct HourBars: View {
    let values: [Double?]
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.line)
                    if let v { RoundedRectangle(cornerRadius: 2).fill(color).frame(height: max(2, 28 * min(1, max(0, v)))) }
                }
                .frame(height: 28)
            }
        }
        .accessibilityHidden(true)
    }
}
