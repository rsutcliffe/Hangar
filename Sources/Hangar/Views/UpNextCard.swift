import SwiftUI

struct UpNextCard: View {
    let queue: [QueuedJob]
    let now: Date

    /// The extra line under a job when its runner situation is unusual.
    static func note(for j: QueuedJob) -> (text: String, stuck: Bool)? {
        guard let e = j.eligible else { return nil }
        if e.isEmpty {
            let what = j.missingLabels.isEmpty ? j.labels : j.missingLabels
            return ("No online runner has: " + what.joined(separator: ", "), true)
        }
        return e.count == 1 ? ("Only \(e[0]) can run this", false) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up next").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Waiting").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 6)
            if queue.isEmpty {
                Text("Queue is empty").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.vertical, 8)
            } else {
                ForEach(queue.prefix(4)) { j in
                    Divider().overlay(Theme.line)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(verbatim: "\(j.repo) · \(j.workflow)" + (j.job.isEmpty || j.job == j.workflow ? "" : " / \(j.job)")).fontWeight(.semibold)
                                + Text(verbatim: " #\(j.runNumber) · \(j.branch)").foregroundColor(Theme.muted))
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            if let note = Self.note(for: j) {
                                Text(note.text).font(.system(size: 10, weight: note.stuck ? .semibold : .regular))
                                    .foregroundStyle(note.stuck ? Theme.problemText : Theme.muted).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(j.isStuck ? "No runner" : j.arch.label).font(.system(size: 10, weight: j.isStuck ? .semibold : .regular))
                            .foregroundStyle(j.isStuck ? Theme.onProblem : Theme.text)
                            .padding(.vertical, 2).padding(.horizontal, 8)
                            .background(j.isStuck ? Theme.problem : Theme.pill, in: Capsule()).frame(width: 66)
                        Text(Format.duration(now.timeIntervalSince(j.queuedAt)))
                            .font(.system(size: 12)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                }
                if queue.count > 4 {
                    Text("+\(queue.count - 4) more").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}
