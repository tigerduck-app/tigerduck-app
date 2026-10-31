import CryptoKit
import Foundation
import Security
import os

/// SPKIs the user accepted for a set by continuing past a mismatch. Valid for one build only.
nonisolated struct TLSPinAcceptance: Codable, Equatable, Sendable {
    let setID: String
    let spkis: Set<String>
    let buildNumber: String
    let acceptedAt: Date
}

/// A refused chain the user may continue past: what the prompt shows and what Continue stores.
nonisolated struct TLSPinMismatch: Equatable, Sendable, Identifiable {
    var id: String { setID }
    let setID: String
    let host: String
    let domains: [String]
    let issuerOrganization: String?
    /// Leaf first, up to the trust anchor.
    let certificates: [TLSCertificateSummary]
    /// The leaf and intermediates, never the root.
    let acceptedSPKIs: Set<String>
    /// Kept to check the document still lists it when the prompt shows and when Continue stores.
    let anchorSPKI: String
    /// Every certificate's, the anchor's too, to tell whether new pins let the chain through.
    var chainSPKIs: Set<String> = []
}

nonisolated enum TLSPinPolicy: Equatable, Sendable {
    case notPinned
    case expired(TLSPinSet)
    case pinned(TLSPinSet)
}

nonisolated enum TLSPinVerdict: Equatable, Sendable {
    case notPinned
    case expired
    case allowed
    case refused(setID: String)
}

nonisolated enum TLSPinDocumentOutcome: Equatable, Sendable {
    case applied
    case unchanged
    case rejected
}

/// The effective pins, the signed document and the user's acceptances, for the phone, the Watch
/// and School Mail. Thread-safe: `MailTLSVerifier` calls it on a NIO event loop.
/// See docs/decisions/0025-remote-tls-pins.md.
nonisolated final class TLSPinEngine: @unchecked Sendable {
    static let shared = TLSPinEngine()

    private struct State {
        var document: TLSPinDocument?
        var acceptances: [TLSPinAcceptance] = []
        var refusedSets: Set<String> = []
        var refreshes: [String: Task<Bool, Never>] = [:]
        var failedRefreshAt: [String: Date] = [:]
    }

    private let matcher: TLSPinMatcher
    private let storage: TLSPinStorage
    private let clock: @Sendable () -> Date
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Security.TLSPin")
    private let lock = NSLock()
    private var loaded: State?
    private var refresh: (@Sendable () async -> Bool)?
    private var report: (@Sendable (TLSPinMismatch) -> Void)?

    init(
        builtIn: [TLSPinSet] = TLSPinTable.builtIn,
        baselineSerial: Int64 = TLSPinTable.baselineSerial,
        keys: [String: Curve25519.Signing.PublicKey] = TLSPinDocument.keys(fromBase64: TLSPinTable.signingKeys),
        defaults: UserDefaults = .standard,
        buildNumber: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        matcher = TLSPinMatcher(builtIn: builtIn, baselineSerial: baselineSerial)
        storage = TLSPinStorage(defaults: defaults, keys: keys, buildNumber: buildNumber)
        self.clock = clock
    }

    /// `refresh` fetches the document again after a mismatch and returns whether the server
    /// answered; `report` takes each refused chain the user may continue past. Both stay nil where
    /// there is no fetch or prompt, as on the Watch.
    func install(
        refresh: (@Sendable () async -> Bool)?,
        report: (@Sendable (TLSPinMismatch) -> Void)?
    ) {
        lock.withLock {
            self.refresh = refresh
            self.report = report
        }
    }

    // MARK: Document

    var storedEnvelope: Data? { withState { $0.document?.envelope } }

    @discardableResult
    func acceptDocument(_ envelope: Data) -> TLSPinDocumentOutcome {
        let document: TLSPinDocument
        do {
            document = try TLSPinDocument.verify(envelope: envelope, keys: storage.keys)
        } catch {
            logger.error("TLS pin document rejected: \(String(describing: error), privacy: .private)")
            return .rejected
        }
        return withState { state in
            guard clock() < document.expiresAt else { return .rejected }
            if let held = state.document {
                if document.serial < held.serial { return .rejected }
                if document.serial == held.serial {
                    return document.payload == held.payload ? .unchanged : .rejected
                }
            }
            state.document = document
            state.refusedSets = []
            storage.saveDocument(envelope)
            logger.notice("TLS pin document \(document.serial, privacy: .public) applied")
            return .applied
        }
    }

    // MARK: Acceptances

    var acceptances: [TLSPinAcceptance] { withState { $0.acceptances } }

    /// Returns whether the set lets the chain through afterwards. A chain still refused is stored
    /// only while `isPromptable` holds, checked under the same lock as the write so a document
    /// applied meanwhile cannot slip between the two.
    @discardableResult
    func accept(_ mismatch: TLSPinMismatch) -> Bool {
        withState { state in
            guard case .pinned(let set) = policy(forHost: mismatch.host, in: state, at: clock()) else { return true }
            if set.pins.isDisjoint(with: mismatch.chainSPKIs) {
                guard isPromptable(mismatch, in: state) else { return false }
                let held = state.acceptances.filter { $0.setID == mismatch.setID }.flatMap(\.spkis)
                let new = mismatch.acceptedSPKIs.subtracting(held)
                if !new.isEmpty {
                    state.acceptances.append(TLSPinAcceptance(
                        setID: mismatch.setID, spkis: new, buildNumber: storage.buildNumber, acceptedAt: clock()
                    ))
                    storage.persist(state.acceptances)
                }
            }
            state.refusedSets.remove(set.id)
            return true
        }
    }

    func replaceAcceptances(with phone: [TLSPinAcceptance]) {
        withState { state in
            state.acceptances = phone.filter { $0.buildNumber == storage.buildNumber }
            state.refusedSets = []
            storage.persist(state.acceptances)
        }
    }

    // MARK: Enforcement

    func policy(forHost host: String, now: Date? = nil) -> TLSPinPolicy {
        withState { policy(forHost: host, in: $0, at: now ?? clock()) }
    }

    /// Checks a chain that already passed system trust, leaf first up to its anchor.
    func evaluate(host: String, chain: [SecCertificate]) -> TLSPinVerdict {
        let spkis = Set(chain.compactMap(TLSSPKI.sha256Base64(of:)))
        return withState { state in
            switch policy(forHost: host, in: state, at: clock()) {
            case .notPinned:
                return .notPinned
            case .expired(let set):
                logger.fault("TLS pins for \(set.id, privacy: .public) expired; \(host, privacy: .public) falls back to system trust")
                return .expired
            case .pinned(let set) where set.pins.isDisjoint(with: spkis):
                return .refused(setID: set.id)
            case .pinned(let set):
                state.refusedSets.remove(set.id)
                return .allowed
            }
        }
    }

    /// After `evaluate` refused `chain`: fetches the document once per set per launch and checks
    /// again. A chain still refused is reported when its anchor is a listed public root.
    func resolveRefusal(host: String, chain: [SecCertificate]) async -> Bool {
        guard case .refused(let setID) = evaluate(host: host, chain: chain) else { return true }
        await refreshOnce(setID: setID)
        guard case .refused = evaluate(host: host, chain: chain) else { return true }
        let anchor = chain.last.flatMap(TLSSPKI.sha256Base64(of:))
        let (mismatch, report) = withState { state in
            state.refusedSets.insert(setID)
            let mismatch = matcher.promptEligible(setID: setID, host: host, chain: chain, anchor: anchor,
                                                  document: state.document, acceptances: state.acceptances, at: clock())
            return (mismatch, self.report)
        }
        if let mismatch {
            logger.error("TLS pin mismatch for \(host, privacy: .public) (set \(setID, privacy: .public)); eligible for a prompt")
            report?(mismatch)
        } else {
            logger.error("TLS pin mismatch for \(host, privacy: .public) (set \(setID, privacy: .public)); refused with no prompt")
        }
        return false
    }

    /// Whether a reported chain may still be continued past. A newer document or the document's
    /// expiry can change the answer while the mismatch waits for the foreground or the user.
    func isPromptable(_ mismatch: TLSPinMismatch) -> Bool {
        withState { isPromptable(mismatch, in: $0) }
    }

    /// Whether the last check of the host's set refused its chain and nothing has changed since.
    func isRefusing(host: String) -> Bool {
        withState { state in
            guard case .pinned(let set) = policy(forHost: host, in: state, at: clock()) else { return false }
            return state.refusedSets.contains(set.id)
        }
    }

    // MARK: Private

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.withLock {
            var state = loaded ?? load()
            defer { loaded = state }
            return body(&state)
        }
    }

    private func load() -> State {
        State(document: storage.storedDocument(), acceptances: storage.storedAcceptances())
    }

    /// A refetch the server answered counts for the launch. After one that failed, as in a network
    /// blip, the next may start 30 seconds later: with the backend out of reach while NTUST answers,
    /// as behind a captive portal, each refused request would otherwise wait out its own refetch.
    private func refreshOnce(setID: String) async {
        let task: Task<Bool, Never>? = withState { state in
            if let running = state.refreshes[setID] { return running }
            if let failed = state.failedRefreshAt[setID],
               clock().timeIntervalSince(failed) < Self.refreshRetryDelay { return nil }
            guard let refresh else { return nil }
            let task = Task { await refresh() }
            state.refreshes[setID] = task
            return task
        }
        guard let task, !(await task.value) else { return }
        withState { state in
            guard state.refreshes[setID] == task else { return }
            state.refreshes[setID] = nil
            state.failedRefreshAt[setID] = clock()
        }
    }

    static let refreshRetryDelay: TimeInterval = 30

    private func policy(forHost host: String, in state: State, at date: Date) -> TLSPinPolicy {
        matcher.policy(forHost: host, document: state.document, acceptances: state.acceptances, at: date)
    }

    private func isPromptable(_ mismatch: TLSPinMismatch, in state: State) -> Bool {
        guard case .pinned(let set) = policy(forHost: mismatch.host, in: state, at: clock()),
              set.id == mismatch.setID, set.pins.isDisjoint(with: mismatch.chainSPKIs) else { return false }
        return TLSPinMatcher.listsPromptRoot(mismatch.anchorSPKI, document: state.document, at: clock())
    }
}
