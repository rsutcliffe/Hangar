import SwiftUI

@main
struct HangarApp: App {
    @State private var store: MonitorStore

    init() {
        let args = CommandLine.arguments
        let demo = args.contains("--demo")
        if args.contains("--light") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }     // for checking Light mode
        if args.contains("--dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        let scenario: DemoBackend.Scenario = args.contains("--scenario-failed") ? .failed : args.contains("--scenario-unreachable") ? .unreachable : args.contains("--scenario-offline") ? .offline : args.contains("--scenario-permission") ? .permission : args.contains("--scenario-pressure") ? .pressure : .stalled
        let backend: MonitorBackend = demo ? DemoBackend(scenario: scenario) : LiveBackend()
        let s = MonitorStore(backend: backend)
        var action: ((MonitorStore) -> Void)?
        if demo, args.contains("--scenario-restarting") { action = { $0.restart("arm-02") } }
        if demo, args.contains("--scenario-paused") { action = { $0.toggleDrain("x86-01") } }
        if demo { s.recordHistory = false; s.memorySustain = 0; s.loadDemoHistory() }
        s.start(demoAction: action)
        if demo, args.contains("--welcome") { s.showWelcome = true }
        _store = State(initialValue: s)
    }

    var body: some Scene {
        WindowGroup("Hangar") {
            MonitorWindow(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(before: .toolbar) {
                Button("Refresh Now") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .windowList) {
                CapacityMenuItem()
            }
        }
        Window("Capacity", id: "capacity") {
            CapacityView(store: store)
        }
        .windowResizability(.contentSize)
        Settings { SettingsView(store: store) }
    }
}

private struct CapacityMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Capacity") { openWindow(id: "capacity") }.keyboardShortcut("c", modifiers: [.command, .option])
    }
}
