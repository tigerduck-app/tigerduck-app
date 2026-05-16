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

    /// Use for binding from a Toggle. Setter clears the override immediately
    /// when toggled off so the app returns to real time without needing the
    /// user to also tap Apply.
    func setEnabled(_ newValue: Bool) {
        enabled = newValue
        if !newValue {
            DebugClockController.shared.setOverride(nil)
        }
    }

    func apply() {
        guard enabled else { return }
        let override = ClockOverride(
            instant: draftInstant,
            frozen: frozen,
            savedAtReal: Date()
        )
        DebugClockController.shared.setOverride(override)
    }

    func reset() {
        DebugClockController.shared.setOverride(nil)
        enabled = false
        draftInstant = Date()
        frozen = true
    }
}
#endif
