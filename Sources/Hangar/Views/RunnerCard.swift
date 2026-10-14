import SwiftUI

struct RunnerCard: View {
    let runner: Runner
    let now: Date
    var onRestart: () -> Void
    var onDrain: () -> Void

    private var s: RunnerState { runner.state }
    private var problem: Bool { s.isProblem }
    private var accent: Color { problem ? Theme.problem : Theme.running }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(runner.id).font(.system(size: 13, weight: .semibold))
                Text(runner.spec).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .lineLimit(1)

            Text(figure)
                .font(.system(size: s == .restarting ? 28 : 38, weight: .semibold))
                .tracking(s == .restarting ? -0.84 : -1.14)
                .monospacedDigit()
                .foregroundStyle(figureColor)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: 38, alignment: .bottomLeading)

            VStack(alignment: .leading, spacing: 2) {
                Text(line1).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Text(line2).font(.system(size: 11, weight: problem ? .semibold : .regular))
                    .foregroundStyle(problem ? Theme.problemText : Theme.muted).lineLimit(1)
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

            HStack(spacing: 6) {
                let busy = s == .restarting
                Group {
                    if problem {
                        Button(action: onRestart) { Text("Restart").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onProblem) }
                            .buttonStyle(.glassProminent).tint(Theme.problem)
                    } else {
                        Button(action: onRestart) { Text("Restart").font(.system(size: 12)) }.buttonStyle(.glass)
                    }
                    Button(action: onDrain) { Text(runner.draining || s == .paused ? "Resume" : "Drain").font(.system(size: 12)) }
                        .buttonStyle(.glass)
                }
                .disabled(busy).opacity(busy ? 0.45 : 1)
            }
            .buttonBorderShape(.capsule).controlSize(.small)
        }
        .padding(.vertical, 18).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay { if problem { RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.problem, lineWidth: 1.5) } }
        .accessibilityElement(children: .combine)
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
        }
    }

    private var figureColor: Color {
        switch s {
        case .running: Theme.running
        case .stalled, .failed: Theme.problem
        case .restarting, .offline: Theme.muted
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
        default: return "No job"
        }
    }

    private var line2: String {
        guard let j = runner.job else {
            if let end = runner.lastJobEndedAt, s == .idle || s == .paused { return "Last ran \(Format.duration(now.timeIntervalSince(end))) ago" }
            return s == .restarting ? "Back shortly" : " "
        }
        switch s {
        case .stalled: return "No output for \(Format.duration(now.timeIntervalSince(j.lastOutputAt)))"
        case .failed:
            let step = j.failedStep ?? j.currentStep
            return j.exitCode.map { "Exit \($0) at step \(step)" } ?? "Failed at step \(step)"
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
    }
}
