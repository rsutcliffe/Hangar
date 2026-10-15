import SwiftUI

struct MonitorWindow: View {
    @Bindable var store: MonitorStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // Scrolls only when the runners would not fit on screen; otherwise the window hugs its content.
        ScrollView(.vertical) {
        TimelineView(.periodic(from: .now, by: 10)) { ctx in
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 12) {
                    header(now: ctx.date)
                    // A Grid (not a lazy one) so the cards in a row share the tallest card's height.
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach(Array(store.runners.chunked(into: 3).enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(row) { r in
                                    RunnerCard(runner: r, now: ctx.date, dimmed: store.isStale(now: ctx.date),
                                               onRestart: { store.restart(r.id) }, onDrain: { store.toggleDrain(r.id) })
                                }
                                // Keep three equal columns when the last row is short.
                                ForEach(0..<(3 - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                            }
                        }
                    }
                    if store.showWelcome {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Welcome.text).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("Got it") { store.dismissWelcome() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                        }
                    }
                    if store.notificationsOff {
                        Text("Notifications are off for Hangar: stalls and failures won't alert you. Enable them in System Settings ▸ Notifications.")
                            .font(.system(size: 11)).foregroundStyle(Theme.problemText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let t = store.tokenWarning {
                        Text(t).font(.system(size: 11)).foregroundStyle(Theme.problemText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let e = store.errorMessage {
                        HStack(alignment: .firstTextBaseline) {
                            Text(e).font(.system(size: 11)).foregroundStyle(Theme.problemText).frame(maxWidth: .infinity, alignment: .leading)
                            if store.needsLocalNetwork {
                                Button("Open Local Network settings") { NSWorkspace.shared.open(LocalNetwork.settingsURL) }
                                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                            }
                        }
                    }
                    UpNextCard(queue: store.queue, now: ctx.date)
                    footer
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

    /// The two places the window doesn't otherwise show (also ⌥⌘C and ⌘,). Kept out of the title bar band, which swallows clicks.
    private var footer: some View {
        HStack(spacing: 14) {
            if let u = store.update {
                Button { NSWorkspace.shared.open(u.url) } label: { Label("Hangar \(u.version) is available", systemImage: "arrow.down.circle") }
                    .foregroundStyle(Theme.running).help("Open the release page to download it")
            }
            Spacer()
            Button { openWindow(id: "capacity") } label: { Label("Capacity", systemImage: "chart.bar.xaxis") }
                .help("Capacity history (⌥⌘C)")
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("Settings (⌘,)")
        }
        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
        .padding(.horizontal, 6)
    }

    /// Leave room for the title bar and Dock; beyond this the runner list scrolls.
    private var maxContentHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 52 }

    private func header(now: Date) -> some View {
        let stale = store.isStale(now: now)
        return headerBody(now: now, stale: stale)
    }

    private func headerBody(now: Date, stale: Bool) -> some View {
        HStack {
            Text("Hangar").font(.system(size: 13, weight: .semibold))
            Text(store.settingUp ? "setting up…" : Freshness.ageText(lastSuccess: store.lastSuccess, now: now))
                .font(.system(size: 11)).foregroundStyle(stale ? Theme.problemText : Theme.muted)
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

extension Array {
    /// Consecutive slices of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
