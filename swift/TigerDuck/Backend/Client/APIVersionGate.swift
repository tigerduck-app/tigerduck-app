import Foundation

/// Latches for good once a TigerDuck backend response retires this app, and the app then asks
/// the user to update. Only backend responses are noted: a 410 from the school's servers means
/// a page moved.
@MainActor
@Observable
final class APIVersionGate {
    static let shared = APIVersionGate()

    static let retiringCodes: Set<String> = ["api_retired", "app_version_retired"]

    private(set) var isRetired = false

    init() {}

    func note(statusCode: Int, code: String? = nil) {
        if !isRetired, Self.retires(status: statusCode, code: code) { isRetired = true }
    }

    nonisolated static func retires(status: Int, code: String?) -> Bool {
        guard status == 410 else { return false }
        guard let code else { return true }
        return retiringCodes.contains(code)
    }

    func resetForTesting() {
        isRetired = false
    }
}
