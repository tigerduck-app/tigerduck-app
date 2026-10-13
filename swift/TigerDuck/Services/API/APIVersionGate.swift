import Foundation

/// Latches when our backend answers `410 Gone`.
///
/// The server retires an API version with 410 rather than 404, so an old
/// build learns it is too old instead of seeing a vague network failure.
/// Only a newer build fixes that, so the user is told plainly. Clients of
/// NTUST, Moodle and the library do not report here: their 410 means a page
/// moved. One-way: retries never revive a retired version, and a banner
/// that came and went would read as a glitch.
@MainActor
@Observable
final class APIVersionGate {
    static let shared = APIVersionGate()

    /// True once any backend call has come back 410.
    private(set) var isRetired = false

    init() {}

    /// Report the status of a response from our own backend.
    ///
    /// Takes the whole status rather than a `Bool` so call sites read as
    /// "tell the gate what happened" and cannot drift into deciding for
    /// themselves what counts as retired.
    func note(statusCode: Int) {
        guard statusCode == 410, !isRetired else { return }
        isRetired = true
    }

    /// Test seam. The singleton latches for the process by design, which
    /// would otherwise leak between test cases.
    func resetForTesting() {
        isRetired = false
    }
}
