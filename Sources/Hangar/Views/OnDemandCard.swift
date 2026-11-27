import SwiftUI

/// Runners the orchestrator started for single jobs. They are not in any host's runner folders, so they never get a card of
/// their own; this lists the live ones, with the job each is running or a note that it is waiting for one.
struct OnDemandCard: View {
    let runners: [OnDemandRunner]
    let now: Date

    /// What a row says about the runner's job.
    static func status(for r: OnDemandRunner) -> String {
        guard let j = r.job else { return r.busy ? "Running a job" : "Waiting for a job" }
        return "\(j.workflow) · \(j.repo) \(j.numberLabel) · \(j.branch)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("On-demand runners").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(runners.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 6)
            ForEach(runners.prefix(6)) { r in
                Divider().overlay(Theme.line)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.set).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if let host = r.host { Text(host).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1) }
                    }
                    .frame(width: 130, alignment: .leading)
                    JobLink(url: r.job?.url) {
                        Text(Self.status(for: r)).font(.system(size: 12)).foregroundStyle(r.job == nil ? Theme.muted : Theme.text)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let j = r.job {
                        Text("step \(j.currentStep)/\(j.totalSteps)").font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(Theme.muted)
                        Text(Format.duration(now.timeIntervalSince(j.startedAt))).font(.system(size: 12)).monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .padding(.vertical, 8)
            }
            if runners.count > 6 {
                Text("+\(runners.count - 6) more").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 2)
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}
