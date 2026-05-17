#if DEBUG
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class DebugSettingsViewModel {
    var enabled: Bool
    var draftInstant: Date
    var frozen: Bool
    private(set) var effectiveNow: Date
    private(set) var lastSimulatedPushStatus: String?

    init() {
        let current = DebugClockController.shared.currentOverride()
        self.enabled = current != nil
        self.draftInstant = current?.instant ?? Date()
        self.frozen = current?.frozen ?? true
        self.effectiveNow = AppClock.now()
    }

    /// Effective-now ticker. Drive from the view's `.task` modifier so
    /// SwiftUI handles cancellation on view disappearance — keeps this
    /// class free of a `deinit` that would otherwise hit Swift 6 strict
    /// concurrency rules around touching MainActor state from deinit.
    func observeEffectiveNow() async {
        effectiveNow = AppClock.now()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            effectiveNow = AppClock.now()
        }
    }

    func setEnabled(_ newValue: Bool) {
        enabled = newValue
        if newValue {
            pushOverride()
        } else {
            DebugClockController.shared.setOverride(nil)
        }
    }

    func setDraftInstant(_ newValue: Date) {
        draftInstant = newValue
        if enabled { pushOverride() }
    }

    func setFrozen(_ newValue: Bool) {
        frozen = newValue
        if enabled { pushOverride() }
    }

    /// `savedAtReal` is stamped at push time — ticking-mode elapsed math
    /// keys off this, so every edit while enabled must restamp it.
    private func pushOverride() {
        let override = ClockOverride(
            instant: draftInstant,
            frozen: frozen,
            savedAtReal: Date()
        )
        DebugClockController.shared.setOverride(override)
    }

    /// Fires a local notification ~3 s from real-now to simulate what a
    /// backend APNs push would look like. Backend pushes can't honor the
    /// debug clock (the server has no idea time is faked), so this exists
    /// purely so QA can visually confirm a "push arrived" while the LA /
    /// widget pipeline is running under a fake-clock override.
    func sendSimulatedPushNow() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                lastSimulatedPushStatus = "Authorization denied"
                return
            }
        case .denied:
            lastSimulatedPushStatus = "Authorization denied — enable in Settings"
            return
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = "Simulated push"
        content.body = "Fake push fired at \(AppClock.now().formatted(date: .omitted, time: .standard)) (app clock)"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(
            identifier: "debug-simulated-push-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            lastSimulatedPushStatus = "Scheduled — arrives in ~3 s (real time)"
        } catch {
            lastSimulatedPushStatus = "Failed: \(error.localizedDescription)"
        }
    }
}
#endif
