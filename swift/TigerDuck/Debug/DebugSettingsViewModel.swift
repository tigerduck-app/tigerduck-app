#if DEBUG
import Foundation
import Observation

@MainActor
@Observable
final class DebugSettingsViewModel {
    var enabled: Bool
    var draftInstant: Date
    var frozen: Bool
    private(set) var effectiveNow: Date

    init() {
        let current = DebugClockController.shared.currentOverride()
        self.enabled = current != nil
        self.draftInstant = current?.instant ?? Date()
        self.frozen = current?.frozen ?? true
        self.effectiveNow = AppClock.now()
    }

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

    private func pushOverride() {
        let override = ClockOverride(
            instant: draftInstant,
            frozen: frozen,
            savedAtReal: Date()
        )
        DebugClockController.shared.setOverride(override)
    }

}
#endif
