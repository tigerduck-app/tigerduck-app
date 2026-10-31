import CryptoKit
import Foundation

/// Whether an upload already went out: per channel, the fingerprint of the last body the backend
/// took, and one send in flight. A newer body waits for the send before it and then goes, so an
/// older body never lands after it; a newer one never cancels the one out.
@MainActor
final class SendLedger {
    nonisolated enum Channel {
        static let assignments = "assignments"
        static let schedule = "schedule"
        static let credentials = "credentials"
        static func courses(_ semester: String) -> String { "courses:\(semester)" }
    }

    /// When an unchanged body goes again.
    nonisolated enum Resend: Equatable, Sendable {
        case always
        case never
        case after(TimeInterval)
    }

    /// Every fetch, sync and push would send an upload the backend answered with an error again at
    /// once, each answered the same way, so a channel that pauses holds the same body this long.
    nonisolated static let refusalPause: TimeInterval = 60

    var clock: () -> Date = { Date() }

    private var accepted: [String: (fingerprint: String, at: Date)] = [:]
    private var failed: [String: String] = [:]
    private var refused: [String: (fingerprint: String, at: Date)] = [:]
    private var forgets = Forgets()
    private var lastSends: [String: Task<Void, Never>] = [:]
    private var unfinished: [String: [String]] = [:]

    private struct Forgets: Equatable {
        var all = 0
        var byChannel: [String: Int] = [:]

        func of(_ channel: String) -> [Int] { [all, byChannel[channel, default: 0]] }
    }

    nonisolated static func isDue(
        accepted: (fingerprint: String, at: Date)?, fingerprint: String, resend: Resend, now: Date
    ) -> Bool {
        guard let accepted, accepted.fingerprint == fingerprint else { return true }
        switch resend {
        case .always: return true
        case .never: return false
        case .after(let interval):
            let age = now.timeIntervalSince(accepted.at)
            return age >= interval || age < 0
        }
    }

    /// Sends `body` on `channel` unless the backend already took it; true when it went out. A
    /// cancelled caller, as a sign-out's, stops its own send rather than waiting for it.
    func send(
        _ channel: String,
        fingerprint: String,
        resend: Resend,
        pausesAfterRefusal: Bool = false,
        isCurrent: @escaping @MainActor () -> Bool,
        _ body: @escaping @MainActor () async throws -> Void
    ) async throws -> Bool {
        let previous = lastSends[channel]
        let send = Task { @MainActor [weak self] () async throws -> Bool in
            await previous?.value
            try Task.checkCancellation()
            guard let self, isCurrent() else { return false }
            return try await self.sendIfDue(
                channel, fingerprint: fingerprint, resend: resend, pauses: pausesAfterRefusal, isCurrent: isCurrent, body
            )
        }
        let ended = Task<Void, Never> { _ = try? await send.value }
        lastSends[channel] = ended
        unfinished[channel, default: []].append(fingerprint)
        defer {
            if lastSends[channel] == ended { lastSends[channel] = nil }
            if let index = unfinished[channel]?.firstIndex(of: fingerprint) { unfinished[channel]?.remove(at: index) }
        }
        return try await withTaskCancellationHandler { try await send.value } onCancel: { send.cancel() }
    }

    private func sendIfDue(
        _ channel: String, fingerprint: String, resend: Resend, pauses: Bool,
        isCurrent: @MainActor () -> Bool, _ body: @MainActor () async throws -> Void
    ) async throws -> Bool {
        let now = clock()
        if resend != .always, isHeldBack(channel, fingerprint: fingerprint, now: now) {
            // An unchanged resend in between cleared the failure, and this body is still unsent.
            failed[channel] = fingerprint
            return false
        }
        guard Self.isDue(accepted: accepted[channel], fingerprint: fingerprint, resend: resend, now: now) else {
            failed[channel] = nil
            return false
        }
        let started = forgets.of(channel)
        do {
            try await body()
        } catch {
            if !AppLogger.isCancellation(error), isCurrent(), started == forgets.of(channel) {
                failed[channel] = fingerprint
                // A 401 the client could not recover from holds nothing back: a sign-in sends again.
                if pauses, case PushAPIError.httpStatus(let status, _, _) = error, status != 401 {
                    refused[channel] = (fingerprint, clock())
                }
            }
            throw error
        }
        guard started == forgets.of(channel) else { return true }
        accepted[channel] = (fingerprint, now)
        failed[channel] = nil
        refused[channel] = nil
        return true
    }

    private func isHeldBack(_ channel: String, fingerprint: String, now: Date) -> Bool {
        guard let refusal = refused[channel], refusal.fingerprint == fingerprint else { return false }
        return (0..<Self.refusalPause).contains(now.timeIntervalSince(refusal.at))
    }

    func accepts(_ channel: String, fingerprint: String) -> Bool {
        accepted[channel]?.fingerprint == fingerprint
    }

    /// A channel under `prefix` holds a body the backend has not taken: one that failed, or one
    /// still out. A failed body it took earlier, as an unchanged resend that failed, is not unsent.
    func holdsUnsent(prefix: String) -> Bool {
        failed.contains { $0.key.hasPrefix(prefix) && !accepts($0.key, fingerprint: $0.value) }
            || unfinished.contains { channel, fingerprints in
                channel.hasPrefix(prefix) && fingerprints.contains { !accepts(channel, fingerprint: $0) }
            }
    }

    /// Forgets what `channel` sent, or every channel's with nil, so the next body goes whatever it
    /// holds; a send out meanwhile records nothing.
    func forget(_ channel: String?) {
        if let channel {
            forgets.byChannel[channel, default: 0] &+= 1
            accepted[channel] = nil
            failed[channel] = nil
            refused[channel] = nil
        } else {
            forgets.all &+= 1
            accepted = [:]
            failed = [:]
            refused = [:]
        }
    }

    /// Forgets every channel whose name starts with one of `prefixes`, as `forget(_:)` does one.
    func forget(prefixes: [String]) {
        let known = Set(accepted.keys).union(failed.keys).union(refused.keys).union(unfinished.keys)
        for channel in known where prefixes.contains(where: channel.hasPrefix) {
            forget(channel)
        }
    }

    /// Waits for the send out on `channel`, if any.
    func settle(_ channel: String) async {
        await lastSends[channel]?.value
    }

    /// A SHA-256 of the body's JSON with sorted keys, the same in every launch.
    nonisolated static func fingerprint(of value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return UUID().uuidString }
        return fingerprint(of: data)
    }

    nonisolated static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
