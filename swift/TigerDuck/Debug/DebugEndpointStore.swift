import Foundation
import os
#if os(iOS)
import UIKit
#endif

/// onboarding's sign-in page or in the Mac settings, and honoured by every build. The Keychain
/// keeps it through the reinstalls done to retest fresh installs against another backend, never
/// restores it via iCloud and lets a launch behind the lock screen read it. A value is stored only
nonisolated enum DebugEndpointStore {
    static let keychainKey = "debug_api_endpoint_override"

    #if os(iOS)
    private static let stored = KeychainReadCache(
        load: { try KeychainManager.loadStringIfReadable(key: keychainKey) },
        forgetOn: [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ]
    )
    #else
    private static let stored = KeychainReadCache(load: { try KeychainManager.loadStringIfReadable(key: keychainKey) })
    #endif

    enum Rejection: Equatable {
        case malformed
        case insecure
        case unreachable(detail: String)
        case notTigerDuck
    }

    static func currentOverride() -> String? {
        guard let raw = stored.value(),
              !raw.isEmpty,
              let url = URL(string: raw),
              PushServerConfig.isOverrideAllowed(url)
        else { return nil }
        return raw
    }

    static func storedButRejectedOverride() -> String? {
        guard let raw = stored.value(),
              !raw.isEmpty
        else { return nil }
        if let url = URL(string: raw), PushServerConfig.isOverrideAllowed(url) {
            return nil
        }
        return raw
    }

    enum CheckResult: Equatable {
        case accepted(URL)
        case rejected(Rejection)
    }

    static func check(_ value: String) async -> CheckResult {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed), parsed.host != nil else {
            return .rejected(.malformed)
        }
        let url = PushServerConfig.normalize(parsed)
        guard PushServerConfig.isOverrideAllowed(url) else { return .rejected(.insecure) }

        switch await EndpointHealthCheck.probe(url) {
        case .unreachable(let detail):
            return .rejected(.unreachable(detail: detail))
        case .notTigerDuck:
            return .rejected(.notTigerDuck)
        case .ok:
            return .accepted(url)
        }
    }

    static func store(_ url: URL) async -> Bool {
        let written = KeychainManager.saveStringReportingSuccess(key: keychainKey, value: url.absoluteString)
        stored.forget()
        if written {
            await AcademicCalendarStore.shared.endpointDidChange()
            await CourseChangeStore.shared.endpointDidChange()
        }
        return written
    }

    @MainActor
    static func clearOverride() {
        KeychainManager.delete(key: keychainKey)
        stored.forget()
        AcademicCalendarStore.shared.endpointDidChange()
        CourseChangeStore.shared.endpointDidChange()
    }
}

nonisolated final class KeychainReadCache: Sendable {
    private struct State {
        var value: String??
        var generation = 0
    }

    private let load: @Sendable () throws -> String?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        load: @escaping @Sendable () throws -> String?,
        forgetOn names: [Notification.Name] = [],
        center: NotificationCenter = .default
    ) {
        self.load = load
        for name in names {
            _ = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.forget()
            }
        }
    }

    func value() -> String? {
        let (cached, generation) = state.withLock { ($0.value, $0.generation) }
        if let cached { return cached }
        let loaded: String?
        do { loaded = try load() } catch { return nil }
        state.withLock { state in
            if state.generation == generation { state.value = .some(loaded) }
        }
        return loaded
    }

    func forget() {
        state.withLock { state in
            state.value = nil
            state.generation &+= 1
        }
    }
}
