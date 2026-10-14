import SwiftUI

@main
struct HangarApp: App {
    @State private var store: MonitorStore

    init() {
        let args = CommandLine.arguments
        let demo = args.contains("--demo")
        let scenario = args.contains("--scenario-failed") ? DemoBackend.Scenario.failed : .stalled
        let backend: MonitorBackend = demo ? DemoBackend(scenario: scenario) : LiveBackend()
        let s = MonitorStore(backend: backend)
        var action: ((MonitorStore) -> Void)?
        if demo, args.contains("--scenario-restarting") { action = { $0.restart("arm-02") } }
        if demo, args.contains("--scenario-paused") { action = { $0.toggleDrain("x86-01") } }
        s.start(demoAction: action)
        _store = State(initialValue: s)
    }

    var body: some Scene {
        WindowGroup("Hangar") {
            MonitorWindow(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        Settings { SettingsView() }
    }
}
