import SwiftUI

struct MonitorWindow: View {
    @Bindable var store: MonitorStore
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 12) {
                    header
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 10) {
                        ForEach(store.runners) { r in
                            RunnerCard(runner: r, now: ctx.date,
                                       onRestart: { store.restart(r.id) }, onDrain: { store.toggleDrain(r.id) })
                        }
                    }
                    if let e = store.errorMessage {
                        Text(e).font(.system(size: 11)).foregroundStyle(Theme.problemText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    UpNextCard(queue: store.queue, now: ctx.date)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .foregroundStyle(Theme.text)
        .frame(width: 644)
        .background { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: Theme.windowRadius)).ignoresSafeArea() }
        .background(WindowChrome())
        .onChange(of: phase) { _, p in store.windowVisible = (p == .active) }
    }

    private var header: some View {
        HStack {
            Text("Hangar").font(.system(size: 13, weight: .semibold))
            Spacer()
            let a = store.queue.count(for: .arm64), x = store.queue.count(for: .x86)
            (Text("\(store.queue.count)").fontWeight(.bold) + Text(" queued · arm64 \(a) · x86 \(x)").foregroundColor(Theme.muted))
                .font(.system(size: 12)).monospacedDigit()
                .padding(.vertical, 4).padding(.horizontal, 10)
                .background(Theme.pill, in: Capsule())
        }
        .frame(height: 28).padding(.leading, 70).padding(.trailing, 6)
        // Sit level with the traffic lights, which live in the title bar area above the content.
        .offset(y: -22).padding(.bottom, -22)
    }
}

/// Clear, shadowed window with the title bar folded into the glass; traffic lights stay system-drawn.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
