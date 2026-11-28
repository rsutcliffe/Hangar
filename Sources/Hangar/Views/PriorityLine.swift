import SwiftUI

/// Where priority stands, under the window's header. It is not part of any section, so collapsing never hides it.
struct PriorityLine: View {
    let status: PriorityStatus
    /// The orchestrator reports a priority now, whatever was last asked of it.
    let canStop: Bool
    let stop: () -> Void

    static func text(_ status: PriorityStatus) -> String? {
        switch status {
        case .off: nil
        case .asking: "Asking the orchestrator…"
        case .on(let repo, let until): "\(repo) first until \(until.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): message
        }
    }

    var body: some View {
        if let text = Self.text(status) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // A Mac's error message can be part of it, so it is never read as Markdown.
                Text(verbatim: text).font(.system(size: 12, weight: .semibold)).foregroundStyle(failed ? Theme.problemText : Theme.text)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if canStop {
                    Button("Stop", action: stop).buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                        .padding(.vertical, 2).padding(.horizontal, 10).background(Theme.pill, in: Capsule())
                        .help("End the priority")
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 16)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
    }

    private var failed: Bool { if case .failed = status { true } else { false } }
}
