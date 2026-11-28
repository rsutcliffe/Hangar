import SwiftUI

struct UpNextCard: View {
    let queue: [QueuedJob]
    let now: Date
    /// The project that is first now, as the orchestrator reports it.
    var priority: String? = nil
    /// The projects that can be put first; empty hides the menu.
    var choices: [String] = []
    var choose: (String) -> Void = { _ in }

    /// A job the orchestrator will favour: only on-demand ones, which are all it places.
    static func isPriority(_ job: QueuedJob, priority: String?) -> Bool {
        job.onDemand && priority.map { job.repo.caseInsensitiveCompare($0) == .orderedSame } == true
    }

    /// The favoured jobs first; otherwise the order they came in.
    static func ordered(_ queue: [QueuedJob], priority: String?) -> [QueuedJob] {
        queue.filter { isPriority($0, priority: priority) } + queue.filter { !isPriority($0, priority: priority) }
    }

    /// The extra line under a job when its runner situation is unusual.
    static func note(for j: QueuedJob) -> (text: String, stuck: Bool)? {
        if j.onDemand { return ("Waiting for an on-demand runner", false) }
        guard let e = j.eligible else { return nil }
        if e.isEmpty {
            let what = j.missingLabels.isEmpty ? j.labels : j.missingLabels
            return ("No online runner has: " + what.joined(separator: ", "), true)
        }
        return e.count == 1 ? ("Only \(e[0]) can run this", false) : nil
    }

    var body: some View {
        CollapsibleSection(.upNext, title: "Up next", summary: .upNext(queue, now: now)) {
            Text("Waiting").font(.system(size: 11)).foregroundStyle(Theme.muted)
        } accessory: {
            if !choices.isEmpty {
                Menu("Prioritise") {
                    ForEach(choices, id: \.self) { repo in Button { choose(repo) } label: { Text(verbatim: repo) } }
                }
                .menuStyle(.borderlessButton).font(.system(size: 11)).fixedSize()
                .help("Give one project's jobs first claim on runner space for two hours")
            }
        } content: {
            if queue.isEmpty {
                Text("Queue is empty").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.vertical, 8)
            } else {
                ForEach(Self.ordered(queue, priority: priority).prefix(4)) { j in
                    Divider().overlay(Theme.line)
                    HStack(spacing: 12) {
                        JobLink(url: j.url) { VStack(alignment: .leading, spacing: 2) {
                            (Text(verbatim: "\(j.repo) · \(j.workflow)" + (j.job.isEmpty || j.job == j.workflow ? "" : " / \(j.job)")).fontWeight(.semibold)
                                + Text(verbatim: " \(j.numberLabel) · \(j.branch)").foregroundColor(Theme.muted))
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            if let note = Self.note(for: j) {
                                Text(note.text).font(.system(size: 10, weight: note.stuck ? .semibold : .regular))
                                    .foregroundStyle(note.stuck ? Theme.problemText : Theme.muted).lineLimit(1)
                            }
                        } }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(j.isStuck ? "No runner" : Self.isPriority(j, priority: priority) ? "Priority" : (j.onDemand ? "On demand" : j.arch.label)).font(.system(size: 10, weight: j.isStuck ? .semibold : .regular))
                            .foregroundStyle(j.isStuck ? Theme.onProblem : Theme.text)
                            .lineLimit(1).minimumScaleFactor(0.8)
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
    }
}
