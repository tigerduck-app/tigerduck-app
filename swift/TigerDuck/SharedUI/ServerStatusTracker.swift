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

nonisolated enum ServerStatus: Equatable {
    case unknown
    case ok
    case failed
}

@Observable
final class ServerStatusTracker {
    static let shared = ServerStatusTracker()

    var statuses: [ServerKind: ServerStatus] = [:]
    private(set) var notes: [ServerKind: String] = [:]

    func set(_ status: ServerStatus, for server: ServerKind, note: String? = nil) {
        statuses[server] = status
        notes[server] = note
    }

    func noteBackendReachable(_ reachable: Bool) {
        guard !Defaults[.cloudSyncEnabled] else { return }
        set(reachable ? .ok : .failed, for: .backend)
    }

    func noteSyncResult(_ ok: Bool) {
        guard Defaults[.cloudSyncEnabled] else { return }
        set(ok ? .ok : .failed, for: .backend)
    }

    func clearBackendStatus() {
        statuses[.backend] = nil
    }

    func status(for server: ServerKind) -> ServerStatus {
        statuses[server] ?? .unknown
    }

    func note(for server: ServerKind) -> String? {
        notes[server]
    }

    func reset() {
        statuses.removeAll()
        notes.removeAll()
    }
}

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
