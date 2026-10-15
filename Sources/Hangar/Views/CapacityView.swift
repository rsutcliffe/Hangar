import SwiftUI

/// Last 24 hours of how busy each runner was and how long the queue got. Opened from Window > Capacity.
struct CapacityView: View {
    var store: MonitorStore

    var body: some View {
        let hours = store.utilisation.recent(count: 24, now: Date())
        let ids = store.utilisation.runnerIDs
        VStack(alignment: .leading, spacing: 14) {
            Text("Capacity · last 24 hours").font(.system(size: 13, weight: .semibold))
            if ids.isEmpty || hours.allSatisfy({ $0.bucket == nil }) {
                Text("Nothing recorded yet. Hangar records one reading per poll and keeps 8 days.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                ForEach(ids, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(id).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(Self.summary(hours: hours.map(\.bucket), runner: id)).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                        }
                        HourBars(values: hours.map { UtilisationLog.busyFraction($0.bucket, runner: id) }, color: Theme.running)
                    }
                }
                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Queue").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(Self.queueSummary(hours.map(\.bucket))).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                    let peak = max(1, hours.compactMap { $0.bucket?.peakQueue }.max() ?? 1)
                    HourBars(values: hours.map { $0.bucket.map { Double($0.peakQueue) / Double(peak) } }, color: Theme.problem)
                }
                HStack {
                    Text("24 h ago").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("now").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .contain)
    }

    /// "62% busy" over the hours the runner was observed.
    static func summary(hours: [HourBucket?], runner: String) -> String {
        let seen = hours.compactMap { $0 }.compactMap { b -> (Int, Int)? in b.total[runner].map { (b.busy[runner] ?? 0, $0) } }
        let total = seen.map(\.1).reduce(0, +)
        guard total > 0 else { return "not seen" }
        return "\(Int((Double(seen.map(\.0).reduce(0, +)) / Double(total) * 100).rounded()))% busy"
    }

    static func queueSummary(_ hours: [HourBucket?]) -> String {
        let peak = hours.compactMap { $0?.peakQueue }.max() ?? 0
        let wait = hours.compactMap { $0?.longestWaitSeconds }.max() ?? 0
        return "peak \(peak) queued · longest wait \(Format.duration(TimeInterval(wait)))"
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
