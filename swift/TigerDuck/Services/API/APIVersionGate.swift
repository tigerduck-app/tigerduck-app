import Foundation

@MainActor
@Observable
final class APIVersionGate {
    static let shared = APIVersionGate()

    private(set) var isRetired = false

    init() {}

    func note(statusCode: Int) {
        guard statusCode == 410, !isRetired else { return }
        isRetired = true
    }

    func resetForTesting() {
        isRetired = false
    }
}
