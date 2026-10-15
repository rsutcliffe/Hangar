import SwiftUI

struct MonitorWindow: View {
    @Bindable var store: MonitorStore
    @Environment(\.scenePhase) private var phase
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // Scrolls only when the runners would not fit on screen; otherwise the window hugs its content.
        ScrollView(.vertical) {
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
                    if store.notificationsOff {
                        Text("Notifications are off for Hangar: stalls and failures won't alert you. Enable them in System Settings ▸ Notifications.")
                            .font(.system(size: 11)).foregroundStyle(Theme.problemText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let e = store.errorMessage {
                        Text(e).font(.system(size: 11)).foregroundStyle(Theme.problemText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    UpNextCard(queue: store.queue, now: ctx.date)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: contentHeight > 0 ? min(contentHeight, maxContentHeight) : nil)
        .foregroundStyle(Theme.text)
        .frame(width: 644)
        .background {
            ZStack {
                Theme.windowShape.fill(Theme.glassFill)
                Color.clear.glassEffect(.regular, in: Theme.windowShape)
            }
            .ignoresSafeArea()
        }
        .background(WindowChrome())
        .onChange(of: phase) { _, p in store.windowVisible = (p == .active) }
    }

    /// Leave room for the title bar and Dock; beyond this the runner list scrolls.
    private var maxContentHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 52 }

    private var header: some View {
        HStack {
            Text("Hangar").font(.system(size: 13, weight: .semibold))
            Spacer()
            let a = store.queue.count(for: .arm64), x = store.queue.count(for: .x86)
            let stuck = store.queue.stuckCount
            (Text("\(store.queue.count)").fontWeight(.bold) + Text(" queued · arm64 \(a) · x86 \(x)").foregroundColor(Theme.muted)
                + (stuck > 0 ? Text(" · \(stuck) stuck").foregroundColor(Theme.problemText).fontWeight(.semibold) : Text("")))
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
/// Also keeps the window on screen: it grows when runners are added, so pull it back into the visible area.
private struct WindowChrome: NSViewRepresentable {
    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { observer.map(NotificationCenter.default.removeObserver) }

        func keepOnScreen(_ w: NSWindow) {
            guard let area = w.screen?.visibleFrame else { return }
            var f = w.frame
            f.origin.y = max(f.origin.y, area.minY)                      // bottom edge inside the visible area
            f.origin.y = min(f.origin.y, area.maxY - f.height)           // top edge too (only bites if taller than the screen)
            f.origin.x = min(max(f.origin.x, area.minX), area.maxX - f.width)
            if f != w.frame { w.setFrame(f, display: true) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
            let c = context.coordinator
            c.observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak c, weak w] _ in
                if let c, let w { c.keepOnScreen(w) }
            }
            c.keepOnScreen(w)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
