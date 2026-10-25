import Foundation

/// Signs the browser in to Moodle without ever showing a signed-out page: Moodle's one-time
/// autologin link first, then the school SSO session the app holds, then a failure the student
/// can retry. A sign-in page reached within ``retryWindow`` of a start means the step before failed.
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
    @ObservationIgnored private var attempt: (target: URL, startedAt: Date, next: Step)?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var runs = 0

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
        if BrowserRouting.isMoodleReturnPage(target), !(await hasSession()) {
            signIn(to: target)
        } else {
            load(target)
        }
    }

    /// A main-frame navigation reached Moodle's sign-in page, which the browser cancelled.
    func reachedSignInPage(returningTo target: URL) {
        guard running == nil else { return }
        if let attempt, now().timeIntervalSince(attempt.startedAt) < Self.retryWindow {
            run()
        } else {
            signIn(to: target)
        }
    }

    func retry() {
        guard running == nil, let target = attempt?.target else { return }
        signIn(to: target)
    }

    /// A page finished loading or failed for good: whatever a sign-in loaded is up.
    func pageSettled() {
        if running == nil { phase = .idle }
    }

    func cancel() {
        running?.cancel()
        running = nil
        runs += 1
        phase = .idle
    }

    /// Waits for the step under way, for tests.
    func settle() async {
        await running?.value
    }

    private func signIn(to target: URL) {
        attempt = (target, now(), .key)
        run()
    }

    private func run() {
        guard let target = attempt?.target else { return }
        phase = .working
        running?.cancel()
        runs += 1
        let run = runs
        running = Task {
            defer { if runs == run { running = nil } }
            if attempt?.next == .key {
                attempt?.next = .session
                if let url = await signedInURL(target) {
                    guard !Task.isCancelled else { return }
                    return load(url)
                }
            }
            if attempt?.next == .session {
                attempt?.next = .none
                if await signInWithSession() {
                    guard !Task.isCancelled else { return }
                    return load(target)
                }
            }
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }
}
