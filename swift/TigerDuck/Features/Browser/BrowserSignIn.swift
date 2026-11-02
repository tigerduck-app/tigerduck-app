import Foundation

/// Signs the browser in to Moodle without ever showing a signed-out page: Moodle's one-time
/// autologin link first, then the school SSO session the app holds, then a failure the student
/// can retry. Another school site that sends the browser to SSO's password form gets the SSO
/// session alone, and the form itself when that fails, for the student to sign in. A sign-in page
/// reached within ``retryWindow`` of the last step for the same site means that step failed.
@MainActor
@Observable
final class BrowserSignIn {
    enum Phase: Equatable { case idle, working, failed }

    private(set) var phase = Phase.idle
    @ObservationIgnored var load: (URL) -> Void = { _ in }
    /// Set by the web view, which hosts the hidden page this sign-in runs in.
    @ObservationIgnored var signInWithSession: () async -> Bool

    @ObservationIgnored private let hasSession: () async -> Bool
    @ObservationIgnored private let signedInURL: (URL) async -> URL?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var attempt: (target: URL, steppedAt: Date, next: Step)?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var runs = 0
    @ObservationIgnored private var closed = false

    private enum Step { case key, session, none }

    static let retryWindow: TimeInterval = 60

    /// The page the sign-in under way, or the last one, goes on to.
    var target: URL? { attempt?.target }

    init(
        hasSession: @escaping () async -> Bool,
        signedInURL: @escaping (URL) async -> URL?,
        signInWithSession: @escaping () async -> Bool = { false },
        now: @escaping () -> Date = { Date() }
    ) {
        self.hasSession = hasSession
        self.signedInURL = signedInURL
        self.signInWithSession = signInWithSession
        self.now = now
    }

    /// Loads `target`, signing in first when it is a Moodle page and the browser has no session.
    func open(_ target: URL) async {
        guard !closed else { return }
        if BrowserRouting.isMoodleReturnPage(target), !(await hasSession()) {
            signIn(to: target)
        } else {
            load(target)
        }
    }

    /// A main-frame navigation on its way to `target` reached a sign-in page; true when the browser
    /// cancels it for this sign-in, false when it shows the page for the student to sign in.
    @discardableResult
    func reachedSignInPage(returningTo target: URL) -> Bool {
        guard running == nil else { return true }
        guard let attempt, BrowserRouting.host(of: attempt.target) == BrowserRouting.host(of: target),
              now().timeIntervalSince(attempt.steppedAt) < Self.retryWindow else {
            signIn(to: target)
            return true
        }
        if attempt.next == .none, Self.leavesFormToStudent(attempt.target) { return false }
        run()
        return true
    }

    func retry() {
        guard running == nil, let target = attempt?.target else { return }
        signIn(to: target)
    }

    /// A page finished loading or failed for good: whatever a sign-in loaded is up.
    func pageSettled() {
        if running == nil { phase = .idle }
    }

    /// The browser closed: what runs stops, and nothing starts again, as each start may spend
    /// Moodle's one autologin key per six minutes.
    func close() {
        closed = true
        running?.cancel()
        running = nil
        runs += 1
        phase = .idle
    }

    /// Waits for the step under way, for tests.
    func settle() async {
        await running?.value
    }

    private static func leavesFormToStudent(_ target: URL) -> Bool {
        !BrowserRouting.isMoodleReturnPage(target)
    }

    private func signIn(to target: URL) {
        attempt = (target, now(), BrowserRouting.isMoodleReturnPage(target) ? .key : .session)
        run()
    }

    private func run() {
        guard !closed, let target = attempt?.target else { return }
        phase = .working
        running?.cancel()
        runs += 1
        let run = runs
        running = Task {
            defer { if runs == run { running = nil } }
            if attempt?.next == .key {
                attempt?.next = .session
                let url = await signedInURL(target)
                guard !Task.isCancelled else { return }
                attempt?.steppedAt = now()
                if let url { return load(url) }
            }
            if attempt?.next == .session {
                attempt?.next = .none
                let signedIn = await signInWithSession()
                guard !Task.isCancelled else { return }
                attempt?.steppedAt = now()
                if signedIn || Self.leavesFormToStudent(target) { return load(target) }
            }
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }
}
