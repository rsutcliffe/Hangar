import SwiftUI

struct SettingsView: View {
    @AppStorage(Config.Key.profiles) private var profiles = "default"
    @AppStorage(Config.Key.hosts) private var hosts = "local"
    @AppStorage(Config.Key.stallMinutes) private var stallMinutes = 10
    @AppStorage(Config.Key.pollSeconds) private var pollSeconds = 15
    @State private var token = ""
    @State private var hasToken = Keychain.token() != nil

    var body: some View {
        Form {
            Section("GitHub (repos are discovered from the runners)") {
                SecureField(hasToken ? "Token saved in Keychain (enter to replace)" : "Token: Actions + Administration read", text: $token)
                    .onSubmit(saveToken)
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
            Section("Monitoring") {
                Stepper("Stall after \(stallMinutes) min", value: $stallMinutes, in: 1...120)
                Stepper("Poll every \(pollSeconds) s", value: $pollSeconds, in: 5...300, step: 5)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private func saveToken() {
        guard !token.isEmpty else { return }
        hasToken = Keychain.write(token)
        token = ""
    }
}
