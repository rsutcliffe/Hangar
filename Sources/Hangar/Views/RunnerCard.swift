import SwiftUI

struct RunnerCard: View {
    let runner: Runner
    let now: Date
    var dimmed = false
    var onRestart: () -> Void
    var onDrain: () -> Void

    private var s: RunnerState { runner.state }
    private var problem: Bool { s.isProblem || runner.restartFailed }
    private var accent: Color { problem ? Theme.problem : Theme.running }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Runner names are agent names and can be long: spec drops below the name when they do not fit.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(runner.id).font(.system(size: 13, weight: .semibold)).fixedSize()
                    Text(runner.spec).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(runner.id).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(runner.spec).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

            Text(figure)
                .font(.system(size: smallFigure ? 28 : 38, weight: .semibold))
                .tracking(smallFigure ? -0.84 : -1.14)
                .monospacedDigit()
                .foregroundStyle(figureColor)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: 38, alignment: .bottomLeading)

            VStack(alignment: .leading, spacing: 2) {
                JobLink(url: runner.job?.url) { Text(line1).font(.system(size: 12)).lineLimit(1).truncationMode(.tail) }
                Text(line2).font(.system(size: 11, weight: problem ? .semibold : .regular))
                    .foregroundStyle(problem ? Theme.problemText : Theme.muted).lineLimit(1)
                ForEach(Array(runner.notes.prefix(2).enumerated()), id: \.offset) { _, n in
                    Text(n.text).font(.system(size: 10, weight: n.urgent ? .semibold : .regular))
                        .foregroundStyle(n.urgent ? Theme.problemText : Theme.muted).lineLimit(1)
                        .help(n.help ?? "")
                }
            }
            .frame(minHeight: 34, alignment: .topLeading)

            ProgressBar(value: s == .running || problem ? (runner.job?.progress ?? 0) : 0, color: accent)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("CPU \(runner.cpuNow)%")
                    Text("MEM \(Format.gb((runner.memUsedGB * 10).rounded() / 10))")
                }
                .font(.system(size: 10)).foregroundStyle(Theme.muted).monospacedDigit()
                Spacer(minLength: 4)
                Sparkline(values: runner.cpuHistory, color: sparkColor)
            }

            Spacer(minLength: 0)         // buttons sit at the bottom, level across a row

            HStack(spacing: 6) {
                let busy = s == .restarting || s == .unreachable
                Group {
                    if problem {
                        Button(action: onRestart) { Text("Restart").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onProblem) }
                            .buttonStyle(.glassProminent).tint(Theme.problem)
                            .accessibilityLabel("Restart \(runner.id)")
                    } else {
                        Button(action: onRestart) { Text("Restart").font(.system(size: 12)) }.buttonStyle(.glass)
                            .accessibilityLabel("Restart \(runner.id)")
                    }
                    Button(action: onDrain) { Text(runner.draining || s == .paused ? "Resume" : "Drain").font(.system(size: 12)) }
                        .buttonStyle(.glass)
                        .accessibilityLabel("\(runner.draining || s == .paused ? "Resume" : "Drain") \(runner.id)")
                }
                .disabled(busy).opacity(busy ? 0.45 : 1)
            }
            .buttonBorderShape(.capsule).controlSize(.small)
        }
        .padding(.vertical, 18).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)     // fill the row, so cards in a row match
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay { if problem { RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.problem, lineWidth: 1.5) } }
        // In the top margin, above the name's line, so a long runner name keeps its full width.
        .overlay(alignment: .topTrailing) {
            if runner.standby {
                Text("Standby").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.vertical, 1).padding(.horizontal, 7)
                    .background(Theme.pill, in: Capsule())
                    .padding(.top, 6).padding(.trailing, 10)
            }
        }
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(runner.accessibilitySummary(now: now) + (dimmed ? ", data is out of date" : ""))
    }

    private var figure: String {
        switch s {
        case .running: "\(Int((runner.job?.progress ?? 0) * 100))%"
        case .stalled: "Stalled"
        case .failed: "Failed"
        case .restarting: "Restarting"
        case .paused: "Paused"
        case .idle: "Idle"
        case .offline: "Offline"
        case .unreachable: "Unreachable"
        }
    }

    private var smallFigure: Bool { s == .restarting || s == .unreachable }

    private var figureColor: Color {
        switch s {
        case .running: Theme.running
        case .stalled, .failed: Theme.problem
        case .restarting, .offline, .unreachable: Theme.muted
        default: Theme.text
        }
    }

    private var sparkColor: Color { s == .running ? Theme.running : problem ? Theme.problem : Theme.muted }

    private var line1: String {
        if let j = runner.job { return j.title }
        switch s {
        case .restarting: return "Restarting runner"
        case .paused: return "Draining finished"
        case .offline: return "Not connected"
        case .unreachable: return "Host unreachable"
        default: return "No job"
        }
    }

    /// "Failed: Checkout" when GitHub names the step, otherwise the step number (and exit code if known).
    static func failureText(_ j: ActiveJob) -> String {
        let step = j.failedStep ?? j.currentStep
        if let name = j.failedStepName { return "Failed: \(name)" }
        return j.exitCode.map { "Exit \($0) at step \(step)" } ?? "Failed at step \(step)"
    }

    private var line2: String {
        guard let j = runner.job else {
            if let end = runner.lastJobEndedAt, s == .idle || s == .paused { return "Last ran \(Format.duration(now.timeIntervalSince(end))) ago" }
            if s == .unreachable { return runner.lastSeenAt.map { "Last seen \(Format.duration(now.timeIntervalSince($0))) ago" } ?? " " }
            if runner.restartFailed { return "Did not come back after restart" }
            return s == .restarting ? "Back shortly" : " "
        }
        switch s {
        case .stalled:
            let quiet = "No output for \(Format.duration(now.timeIntervalSince(j.lastOutputAt)))"
            return runner.runnerCPU == nil ? quiet : quiet + " · idle"
        case .failed:
            return Self.failureText(j)
        default:
            let tail = runner.draining ? " · draining" : ""
            return "Step \(j.currentStep) of \(j.totalSteps) · \(Format.duration(now.timeIntervalSince(j.startedAt)))\(tail)"
        }
    }
}

struct ProgressBar: View {
    var value: Double
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(color).frame(width: g.size.width * min(1, max(0, value)))
                    .animation(.easeInOut(duration: 0.8), value: value)
            }
        }
        .frame(height: 5)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
    }
}

/// A job title that opens the job on GitHub when it has a safe link; plain text otherwise.
struct JobLink<Label: View>: View {
    let url: URL?
    @ViewBuilder var label: () -> Label

    var body: some View {
        if let url {
            Button { GitHubLink.open(url) } label: { label() }
                .buttonStyle(.plain)
                .help("Open on GitHub")
                .accessibilityHint("Opens the job on GitHub")
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        } else {
            label()
        }
    }
}
