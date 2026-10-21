import Foundation
import UserNotifications

/// One notification per (job, event). Copy matches the handover README exactly.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    enum Event: String { case stalled, failed }
    private var gate = NotifyGate.load()

    /// Asks once; `onDenied` runs on the main actor if the user has turned Hangar's notifications off.
    func requestAuthorization(onDenied: @escaping @MainActor () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if !granted { Task { @MainActor in onDenied() } }
        }
    }

    /// False when the user has switched off "Badge app icon" for Hangar, which hides the Dock badge.
    nonisolated static func badgeAllowed() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return s.authorizationStatus != .denied && s.badgeSetting != .disabled
    }

    /// The Dock badge goes through the notification centre too, so it follows the user's "Badge app icon" setting.
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    /// A non-urgent notice (disk, long run, failure pattern). The caller decides when it may be shown.
    /// `key` names the thing being reported (not its wording, which can change), so the same condition is not announced again for `NotifyGate.noticeCooldown`.
    func notifyNotice(key: String, title: String, body: String) {
        guard allow("notice:\(key)", cooldown: NotifyGate.noticeCooldown) else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        c.threadIdentifier = "notices"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "notice-\(abs(key.hashValue))-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
    }

    /// Applies the persisted cooldown and the global burst cap. Anything over the cap is folded into one summary alert.
    private func allow(_ key: String, cooldown: TimeInterval) -> Bool {
        let verdict = gate.allow(key, cooldown: cooldown, now: Date())
        gate.save()
        switch verdict {
        case .send: return true
        case .suppressed: return false
        case .burst(let needsSummary):
            if needsSummary {
                let c = UNMutableNotificationContent()
                c.title = "More Hangar alerts"
                c.body = "Several alerts were held back so they do not flood you. Open Hangar to see what needs attention."
                c.threadIdentifier = "notices"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hangar-summary", content: c, trigger: nil))
            }
            return false
        }
    }

    func notifyRestartFailed(runner: String, host: String) {
        guard allow("restart:\(runner)", cooldown: NotifyGate.outageCooldown) else { return }
        let c = UNMutableNotificationContent()
        c.title = "Runner did not come back"
        c.body = host.isEmpty ? "\(runner) is still offline after a restart." : "\(runner) on \(host) is still offline after a restart."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "restart-\(runner)-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
    }

    /// One alert per confirmed outage; the tracker guarantees it is only called once per outage.
    func notifyOffline(runner: String, host: String) {
        guard allow("offline:\(runner)", cooldown: NotifyGate.outageCooldown) else { return }
        let text = NotificationText.offline(runner: runner, host: host)
        let c = UNMutableNotificationContent()
        c.title = text.title; c.body = text.body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "offline-\(runner)-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
    }

    /// Without this, macOS silently drops notifications while Hangar is the frontmost app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Returns true if it was new (not previously sent).
    @discardableResult
    func notify(_ event: Event, jobId: Int, runner: String, job: ActiveJob, silentMinutes: Int) -> Bool {
        guard allow("job:\(jobId):\(event.rawValue)", cooldown: NotifyGate.jobCooldown) else { return false }
        let c = UNMutableNotificationContent()
        switch event {
        case .stalled:
            c.title = "Runner stalled"
            c.body = "\(runner) has had no output for \(silentMinutes) minutes on \(job.workflow) · \(job.repo) #\(job.runNumber)."
        case .failed:
            c.title = "Job failed"
            let step = job.failedStep ?? job.currentStep
            c.body = job.exitCode.map { "\(job.title) on \(runner) exited with code \($0) at step \(step)." }
                ?? "\(job.title) on \(runner) failed at step \(step)."
        }
        c.sound = .default
        c.threadIdentifier = event.rawValue
        let req = UNNotificationRequest(identifier: "\(jobId)-\(event.rawValue)-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        return true
    }
}
