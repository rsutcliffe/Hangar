import Foundation
import Observation
import ServiceManagement

enum LoginItemState: Equatable { case on, off, needsApproval, unavailable }

/// The system's login item for this app. Behind a protocol so the toggle logic can be tested without touching real settings.
protocol LoginItemService {
    var state: LoginItemState { get }
    func set(_ on: Bool) throws
    func openLoginItemsSettings()
}

struct SystemLoginItem: LoginItemService {
    private var service: SMAppService { .mainApp }

    var state: LoginItemState {
        switch service.status {
        case .enabled: .on
        case .notRegistered: .off
        case .requiresApproval: .needsApproval
        default: .unavailable
        }
    }

    func set(_ on: Bool) throws {
        if on { if service.status != .enabled { try service.register() } } else { try service.unregister() }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Drives the Settings toggle from the live system status rather than a stored flag, since the user can change it in System Settings.
@Observable @MainActor
final class LoginItemModel {
    private let service: LoginItemService
    private(set) var state: LoginItemState
    private(set) var error: String?

    init(service: LoginItemService = SystemLoginItem()) {
        self.service = service
        state = service.state
    }

    /// On (or waiting for approval, which the user has asked for) counts as the toggle being on.
    var isOn: Bool { state == .on || state == .needsApproval }

    func refresh() { state = service.state }

    func setOn(_ on: Bool) {
        do { try service.set(on); error = nil } catch { self.error = "Could not change the login item: \(error.localizedDescription)" }
        state = service.state
    }

    func openSettings() { service.openLoginItemsSettings() }
}

enum ProblemBadge {
    /// Runners that need attention: stalled or failed.
    static func count(_ runners: [Runner]) -> Int { runners.filter { $0.state.isProblem }.count }

    static func label(_ count: Int) -> String? { count > 0 ? String(count) : nil }
}
