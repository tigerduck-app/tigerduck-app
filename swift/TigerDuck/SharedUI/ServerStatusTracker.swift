import Defaults
import Foundation

enum ServerKind: String, CaseIterable, Identifiable {
    case moodle
    case courseSelection
    case backend

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .moodle: "graduationcap.fill"
        case .courseSelection: "list.clipboard.fill"
        case .backend: "cloud.fill"
        }
    }

    var label: String {
        switch self {
        case .moodle: "Moodle"
        case .courseSelection: "Course Selection"
        case .backend: "TigerDuck Backend"
        }
    }
}

enum ServerStatus: Equatable {
    case unknown
    case ok
    case failed
}

@Observable
final class ServerStatusTracker {
    static let shared = ServerStatusTracker()

    var statuses: [ServerKind: ServerStatus] = [:]

    func set(_ status: ServerStatus, for server: ServerKind) {
        statuses[server] = status
    }

    /// Report whether a *public* backend call got through.
    ///
    /// The academic calendar refresh is an unauthenticated GET that runs on
    /// every app open no matter how TigerSync is configured, which makes it
    /// the one caller that can keep the backend's row honest when there is no
    /// sync to report: it reads reachable-but-minimal, or failed, rather than
    /// sitting grey and unexplained forever. (The bulletin feed is public too
    /// and could report here; the calendar is the one that always runs.)
    ///
    /// Ignored while sync is on. There the sync is the more demanding call and
    /// its result is the authoritative one — letting a public GET that
    /// happened to land later paint over a sync failure would hide exactly the
    /// breakage the dot exists to surface.
    func noteBackendReachable(_ reachable: Bool) {
        guard !Defaults[.cloudSyncEnabled] else { return }
        set(reachable ? .ok : .failed, for: .backend)
    }

    /// Drop the backend reading when sync is switched on or off.
    ///
    /// The slot means a different thing on each side of that flip — a full
    /// sync result vs. a public GET's reachability — so a reading taken under
    /// the old meaning must not survive it. The next fetch of either kind
    /// fills it back in.
    func clearBackendStatus() {
        statuses[.backend] = nil
    }

    func status(for server: ServerKind) -> ServerStatus {
        statuses[server] ?? .unknown
    }

    func reset() {
        statuses.removeAll()
    }
}

// MARK: - Simulated failures (DEBUG only)

#if DEBUG
enum SimulatedFailure: String, CaseIterable, Identifiable {
    case none
    case timeout
    case http500
    case http401
    case http403
    case slow
    case unreachable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Normal"
        case .timeout: "Timeout (30s)"
        case .http500: "HTTP 500"
        case .http401: "HTTP 401"
        case .http403: "HTTP 403"
        case .slow: "Slow (10s delay)"
        case .unreachable: "Unreachable"
        }
    }
}

@Observable
final class ServerFailureSimulator {
    static let shared = ServerFailureSimulator()

    var failures: [ServerKind: SimulatedFailure] = [:]

    func failure(for server: ServerKind) -> SimulatedFailure {
        failures[server] ?? .none
    }

    func check(_ server: ServerKind) async throws {
        let f = await MainActor.run { failure(for: server) }
        guard f != .none else { return }
        switch f {
        case .none:
            break
        case .timeout:
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        case .http500:
            throw URLError(.badServerResponse)
        case .http401:
            throw URLError(.userAuthenticationRequired)
        case .http403:
            throw URLError(.noPermissionsToReadFile)
        case .slow:
            try await Task.sleep(for: .seconds(10))
        case .unreachable:
            throw URLError(.cannotConnectToHost)
        }
    }
}
#endif
