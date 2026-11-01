import Foundation
import Observation

@MainActor
final class DeviceSurfaceSyncer {
    struct Fingerprint: Equatable {
        var data: AppDataRevision
        var language: String
        var accentHex: Int
        var visualPreset: String
        var signedIn: Bool
        var unobserved: UnobservedChanges

        func differsOnlyInVisualPreset(from other: Fingerprint) -> Bool {
            var withOtherPreset = self
            withOtherPreset.visualPreset = other.visualPreset
            return withOtherPreset == other && visualPreset != other.visualPreset
        }
    }

    struct UnobservedChanges: Equatable {
        var other = 0
        var locale = 0
    }

    struct Surfaces {
        var widgets: (_ forceReload: Bool) -> Void
        var watch: () -> Void = {}
        var liveActivity: () -> Void = {}
    }

    static let debounce: Duration = .milliseconds(250)

    private let surfaces: Surfaces
    private let fingerprint: (UnobservedChanges) -> Fingerprint
    private let sleep: (Duration) async -> Void
    private var unobserved = UnobservedChanges()
    private var last: Fingerprint
    private var pending: Task<Void, Never>?
    private var observation: StoreObservation?
    private let center: NotificationCenter
    private nonisolated(unsafe) var tokens: [any NSObjectProtocol] = []

    init(
        surfaces: Surfaces,
        fingerprint: @escaping (UnobservedChanges) -> Fingerprint,
        center: NotificationCenter = .default,
        sleep: @escaping (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) }
    ) {
        self.surfaces = surfaces
        self.fingerprint = fingerprint
        self.sleep = sleep
        self.center = center
        last = fingerprint(UnobservedChanges())
        observation = StoreObservation(read: { [weak self] in
            guard let self else { return }
            _ = self.fingerprint(self.unobserved)
        }) { [weak self] in
            self?.scheduleRefresh()
        }
        tokens = Self.unobservedChangeNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.nudge(\.other) }
            }
        }
        tokens.append(center.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudge(\.locale) }
        })
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }

    private static var unobservedChangeNames: [Notification.Name] {
        var names = [AppConstants.holidayNotifyDidChange, AppConstants.courseSkipStateDidChange]
        #if DEBUG
        names.append(DebugClockController.didChangeNotification)
        #endif
        return names
    }

    private func nudge(_ count: WritableKeyPath<UnobservedChanges, Int>) {
        unobserved[keyPath: count] &+= 1
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        pending?.cancel()
        pending = Task { [weak self, sleep] in
            await sleep(Self.debounce)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        let now = fingerprint(unobserved)
        let previous = last
        guard now != previous else { return }
        last = now
        surfaces.watch()
        guard !now.differsOnlyInVisualPreset(from: previous) else { return }
        surfaces.widgets(previous.language != now.language || previous.unobserved.locale != now.unobserved.locale)
        surfaces.liveActivity()
    }
}

extension DeviceSurfaceSyncer {
    static func fingerprint(of app: AppEnvironment, unobserved: UnobservedChanges) -> Fingerprint {
        Fingerprint(
            data: .current,
            language: app.preferences.appLanguage,
            accentHex: app.preferences.accentColorHex,
            visualPreset: app.preferences.visualPreset.rawValue,
            signedIn: app.authService.hasStoredCredentials,
            unobserved: unobserved
        )
    }
}
