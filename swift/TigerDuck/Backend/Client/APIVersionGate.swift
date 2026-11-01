import Foundation

@MainActor
@Observable
final class APIVersionGate {
    static let shared = APIVersionGate()

    static let retiringCodes: Set<String> = ["api_retired", "app_version_retired"]

    private(set) var isRetired = false

    init() {}

    func note(statusCode: Int, code: String? = nil) {
        guard statusCode == 410, !isRetired else { return }
        if let code, !Self.retiringCodes.contains(code) { return }
        isRetired = true
    }

    func resetForTesting() {
        isRetired = false
    }
}
