import SwiftUI

/// The parts of the window that can be collapsed. Each remembers its own choice.
enum CardSection: String, CaseIterable {
    case orchestrator, onDemand, upNext, throughput, runners

    var key: String { "collapsed.\(rawValue)" }
}

/// What a collapsed section's one line says. `problem` is shown in red.
struct SectionSummary: Equatable {
    var text = ""
    var problem = ""

    static func orchestrator(_ parts: [OrchestratorCard.Part]) -> SectionSummary {
        // The card's first part is its state; the rest is history.
        switch parts.first {
        case .noProblems: return .init(text: "No problems")
        case .problems(let rows): return .init(problem: rows.count == 1 ? "1 problem" : "\(rows.count) problems")
        case .notReporting: return .init(problem: "Orchestrator not reporting")
        case .cannotReach(let mac, _): return .init(problem: "Cannot reach \(mac)")
        case .needsUpdate: return .init(problem: "Hangar needs updating")
        default: return .init()
        }
    }

    static func onDemand(_ runners: [OnDemandRunner]) -> SectionSummary {
        let busy = runners.filter(\.busy).count, idle = runners.count - busy
        return .init(text: [busy > 0 ? "\(busy) running" : "", idle > 0 ? "\(idle) idle" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    static func upNext(_ queue: [QueuedJob], now: Date) -> SectionSummary {
        guard let first = queue.map(\.queuedAt).min() else { return .init(text: "Queue is empty") }
        let stuck = queue.stuckCount
        return .init(text: "\(queue.count) waiting · longest \(Format.duration(now.timeIntervalSince(first)))",
                     problem: stuck > 0 ? "\(stuck) stuck" : "")
    }

    static func throughput(doneLastHour: Int?, failed6h: Int?) -> SectionSummary {
        .init(text: doneLastHour.map { "\($0.formatted()) done last hour" } ?? "",
              problem: (failed6h ?? 0) > 0 ? "\((failed6h ?? 0).formatted()) failed in 6 hours" : "")
    }

    static func runners(total: Int, problems: Int) -> SectionSummary {
        .init(text: total == 1 ? "1 runner" : "\(total) runners",
              problem: problems > 0 ? "\(problems) \(problems == 1 ? "needs" : "need") attention" : "")
    }
}

/// A heading that shows or hides what is under it. Collapsed, it is one line with a summary, so nothing goes unnoticed.
struct CollapsibleSection<Trailing: View, Content: View>: View {
    private let title: String
    private let summary: SectionSummary
    /// False draws no card around the open section, for content that brings its own cards.
    private let card: Bool
    private let spacing: CGFloat
    private let trailing: Trailing
    private let content: Content
    @AppStorage private var collapsed: Bool

    init(_ section: CardSection, title: String, summary: SectionSummary, card: Bool = true, spacing: CGFloat = 0,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.card = card
        self.spacing = spacing
        self.trailing = trailing()
        self.content = content()
        _collapsed = AppStorage(wrappedValue: false, section.key)
    }

    var body: some View {
        let boxed = card || collapsed
        VStack(alignment: .leading, spacing: 0) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.muted).frame(width: 10)
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                    Spacer(minLength: 12)
                    if collapsed { summaryLine } else { trailing }
                }
                .padding(.horizontal, boxed ? 0 : 16)                   // lines up with the headings of the boxed sections
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show \(title)" : "Hide \(title)")
            .accessibilityLabel(Text(verbatim: ([title] + (collapsed ? [summary.problem, summary.text] : [])).filter { !$0.isEmpty }
                .joined(separator: ", ")))
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            if !collapsed {
                VStack(alignment: .leading, spacing: spacing) { content }.padding(.top, max(6, spacing))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, boxed ? 14 : 0).padding(.horizontal, boxed ? 16 : 0)
        .background { if boxed { RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.cardFill) } }
    }

    /// The problem comes first and is never cut. A Mac's name in it is shown verbatim.
    private var summaryLine: some View {
        HStack(spacing: 8) {
            if !summary.problem.isEmpty {
                Text(verbatim: summary.problem).foregroundStyle(Theme.problemText).fontWeight(.semibold).layoutPriority(1)
            }
            if !summary.text.isEmpty { Text(verbatim: summary.text).foregroundStyle(Theme.muted) }
        }
        .font(.system(size: 11)).monospacedDigit().lineLimit(1)
    }
}
