import SwiftUI

struct UpNextCard: View {
    let queue: [QueuedJob]
    let now: Date

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
                        (Text(verbatim: "\(j.repo) · \(j.workflow)").fontWeight(.semibold)
                            + Text(verbatim: " #\(j.runNumber) · \(j.branch)").foregroundColor(Theme.muted))
                            .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(j.arch.label).font(.system(size: 10)).padding(.vertical, 2).padding(.horizontal, 8)
                            .background(Theme.pill, in: Capsule()).frame(width: 60)
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
