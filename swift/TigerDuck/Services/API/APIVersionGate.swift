import Foundation

/// Latches when our backend answers `410 Gone`.
///
/// The server retires an API version by answering every request to it with
/// 410 rather than 404, precisely so a build talking to a version that no
/// longer exists gets an unambiguous "this app is too old" instead of a
/// shapeless network failure. Nothing the app can do fixes it — the only
/// remedy is a newer build — so it is worth telling the user plainly
/// rather than letting every screen fail on its own.
///
/// Only clients that talk to *our* backend report in here. The NTUST,
/// Moodle and library clients deliberately do not: a 410 from the school's
/// servers means one of their pages moved, which says nothing about the
/// app's version.
///
/// One-way on purpose. Once the server has said a version is gone, no
/// amount of retrying brings it back, and a banner that came and went as
/// unrelated requests happened to succeed would read as a glitch rather
/// than as the permanent state it is.
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
