import SwiftUI

struct SettingsView: View {
    @AppStorage(Config.Key.owner) private var owner = ""
    @AppStorage(Config.Key.repos) private var repos = ""
    @AppStorage(Config.Key.profiles) private var profiles = ""
    @AppStorage(Config.Key.runnerDir) private var runnerDir = "~/actions-runner"
    @AppStorage(Config.Key.stallMinutes) private var stallMinutes = 10
    @AppStorage(Config.Key.pollSeconds) private var pollSeconds = 15
    @State private var token = ""
    @State private var hasToken = Keychain.read() != nil

    var body: some View {
        Form {
            Section("GitHub") {
                TextField("Org or user", text: $owner)
                TextField("Repos (comma separated)", text: $repos)
                SecureField(hasToken ? "Token saved in Keychain (enter to replace)" : "Fine-grained token (actions:read)", text: $token)
                    .onSubmit(saveToken)
                HStack {
                    Button("Save token", action: saveToken).disabled(token.isEmpty)
                    Button("Remove token", role: .destructive) { Keychain.delete(); hasToken = false }.disabled(!hasToken)
                }
            }
            Section("Colima") {
                TextField("Profiles (comma separated)", text: $profiles)
                TextField("Runner directory in VM", text: $runnerDir)
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
