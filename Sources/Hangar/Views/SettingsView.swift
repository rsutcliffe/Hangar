import SwiftUI

struct SettingsView: View {
    var store: MonitorStore
    @AppStorage(Config.Key.profiles) private var profiles = "default"
    @AppStorage(Config.Key.hosts) private var hosts = "local"
    @AppStorage(Config.Key.stallMinutes) private var stallMinutes = 10
    @AppStorage(Config.Key.pollSeconds) private var pollSeconds = 15
    @State private var token = ""
    @State private var hasToken = Keychain.token() != nil
    @State private var loginItem = LoginItemModel()
    @State private var badgeAllowed = true
    @AppStorage(Config.Key.quietEnabled) private var quietEnabled = false
    @AppStorage(Config.Key.quietStart) private var quietStart = 22
    @AppStorage(Config.Key.quietEnd) private var quietEnd = 7
    @State private var report: ConnectionReport?
    @State private var testing = false

    var body: some View {
        Form {
            Section("GitHub (repos are discovered from the runners)") {
                SecureField(hasToken ? "Token saved in Keychain (enter to replace)" : "Token: Actions + Administration read", text: $token)
                    .onSubmit(saveToken)
                if let e = store.tokenExpiry {
                    Text("Token expires \(e.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save token", action: saveToken).disabled(token.isEmpty)
                    Button("Remove token", role: .destructive) { Keychain.delete(); hasToken = false }.disabled(!hasToken)
                }
            }
            Section("Hosts") {
                TextField("One per line: local, or an SSH target", text: $hosts, axis: .vertical).lineLimit(2...5)
                Text("SSH uses your existing key; Hangar never asks for a password.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Colima") {
                TextField("Profiles (comma separated)", text: $profiles)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setOn($0) }))
                if loginItem.state == .needsApproval {
                    HStack {
                        Text("Allow Hangar in System Settings ▸ General ▸ Login Items.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { loginItem.openSettings() }.controlSize(.small)
                    }
                }
                if let e = loginItem.error { Text(e).font(.caption).foregroundStyle(.red) }
                if !badgeAllowed {
                    Text("The Dock badge is off. Turn on “Badge app icon” for Hangar in System Settings ▸ Notifications.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Quiet hours") {
                Toggle("Hold non-urgent alerts", isOn: $quietEnabled)
                if quietEnabled {
                    Stepper("From \(String(format: "%02d", quietStart)):00", value: $quietStart, in: 0...23)
                    Stepper("Until \(String(format: "%02d", quietEnd)):00", value: $quietEnd, in: 0...23)
                    Text("Stalls, failures and outages still alert. Disk, long-run and repeat-failure notices wait.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Connection") {
                Button(testing ? "Testing…" : "Test connection") {
                    testing = true
                    Task { report = await store.diagnose(); testing = false }
                }.disabled(testing)
                if let report {
                    ForEach(Array(report.lines.enumerated()), id: \.offset) { _, l in
                        Label(l.text, systemImage: l.ok ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(l.ok ? Color.secondary : Theme.problemText)
                    }
                }
            }
            Section("Monitoring") {
                Stepper("Stall after \(stallMinutes) min", value: $stallMinutes, in: 1...120)
                Stepper("Poll every \(pollSeconds) s", value: $pollSeconds, in: 5...300, step: 5)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 900)
        .onAppear { loginItem.refresh(); Task { badgeAllowed = await NotificationService.badgeAllowed() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh(); Task { badgeAllowed = await NotificationService.badgeAllowed() } }
    }

    private func saveToken() {
        guard !token.isEmpty else { return }
        hasToken = Keychain.write(token)
        token = ""
    }
}
