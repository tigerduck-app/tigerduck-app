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

    private enum Key {
        static let document = "tlsPinDocumentEnvelope"
        static let acceptances = "tlsPinAcceptances"
    }

    private struct State {
        var document: TLSPinDocument?
        var acceptances: [TLSPinAcceptance] = []
        var refusedSets: Set<String> = []
        var refreshes: [String: Task<Void, Never>] = [:]
    }

    private let builtIn: [TLSPinSet]
    private let baselineSerial: Int64
    private let keys: [String: Curve25519.Signing.PublicKey]
    private let defaults: UserDefaults
    private let buildNumber: String
    private let clock: @Sendable () -> Date
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Security.TLSPin")
    private let lock = NSLock()
    private var loaded: State?
    private var refresh: (@Sendable () async -> Void)?
    private var report: (@Sendable (TLSPinMismatch) -> Void)?

    init(
        builtIn: [TLSPinSet] = TLSPinTable.builtIn,
        baselineSerial: Int64 = TLSPinTable.baselineSerial,
        keys: [String: Curve25519.Signing.PublicKey] = TLSPinDocument.keys(fromBase64: TLSPinTable.signingKeys),
        defaults: UserDefaults = .standard,
        buildNumber: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.builtIn = builtIn
        self.baselineSerial = baselineSerial
        self.keys = keys
        self.defaults = defaults
        self.buildNumber = buildNumber
        self.clock = clock
    }

    /// `refresh` fetches the document again after a mismatch; `report` takes each refused chain the
    /// user may continue past. Both stay nil where there is no fetch or prompt, as on the Watch.
    func install(
        refresh: (@Sendable () async -> Void)?,
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
            document = try TLSPinDocument.verify(envelope: envelope, keys: keys)
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
            defaults.set(envelope, forKey: Key.document)
            logger.notice("TLS pin document \(document.serial, privacy: .public) applied")
            return .applied
        }
    }

    // MARK: Acceptances

    var acceptances: [TLSPinAcceptance] { withState { $0.acceptances } }

    func accept(_ mismatch: TLSPinMismatch) {
        withState { state in
            state.acceptances.append(TLSPinAcceptance(
                setID: mismatch.setID, spkis: mismatch.acceptedSPKIs, buildNumber: buildNumber, acceptedAt: clock()
            ))
            state.refusedSets.remove(mismatch.setID)
            persist(state.acceptances)
        }
    }

    /// The Watch takes the phone's list whole, keeping only acceptances made under its own build.
    func replaceAcceptances(with phone: [TLSPinAcceptance]) {
        withState { state in
            state.acceptances = phone.filter { $0.buildNumber == buildNumber }
            state.refusedSets = []
            persist(state.acceptances)
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
            return (promptEligible(setID: setID, host: host, chain: chain, anchor: anchor, in: state), self.report)
        }
        if let mismatch {
            logger.error("TLS pin mismatch for \(host, privacy: .public) (set \(setID, privacy: .public)); eligible for a prompt")
            report?(mismatch)
        } else {
            logger.error("TLS pin mismatch for \(host, privacy: .public) (set \(setID, privacy: .public)); refused with no prompt")
        }
        return false
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

    /// Stored values are checked again on every load, and acceptances from another build dropped.
    private func load() -> State {
        var state = State()
        if let envelope = defaults.data(forKey: Key.document) {
            state.document = try? TLSPinDocument.verify(envelope: envelope, keys: keys)
            if state.document == nil {
                logger.error("Stored TLS pin document failed verification; dropped")
                defaults.removeObject(forKey: Key.document)
            }
        }
        if let data = defaults.data(forKey: Key.acceptances),
           let stored = try? JSONDecoder().decode([TLSPinAcceptance].self, from: data) {
            state.acceptances = stored.filter { $0.buildNumber == buildNumber }
            if state.acceptances.count != stored.count { persist(state.acceptances) }
        }
        return state
    }

    private func persist(_ acceptances: [TLSPinAcceptance]) {
        if let data = try? JSONEncoder().encode(acceptances) {
            defaults.set(data, forKey: Key.acceptances)
        }
    }

    private func refreshOnce(setID: String) async {
        let task: Task<Void, Never>? = withState { state in
            if let running = state.refreshes[setID] { return running }
            guard let refresh else { return nil }
            let task = Task { await refresh() }
            state.refreshes[setID] = task
            return task
        }
        await task?.value
    }

    /// The sets the document replaces, when it is newer than the built-in table; a set it does not
    /// list keeps the built-in pins, and an expiry it moves earlier is ignored.
    private func effectiveSets(in state: State, at date: Date) -> [TLSPinSet] {
        let document = state.document.flatMap { $0.serial > baselineSerial && date < $0.expiresAt ? $0 : nil }
        return builtIn.map { local in
            let remote = document?.pinSets.first { $0.id == local.id }
            let accepted = state.acceptances.filter { $0.setID == local.id }.flatMap(\.spkis)
            return TLSPinSet(
                id: local.id,
                domains: remote?.domains ?? local.domains,
                pins: (remote?.pins ?? local.pins).union(accepted),
                expiresAt: max(local.expiresAt, remote?.expiresAt ?? local.expiresAt)
            )
        }
    }

    /// The most specific match wins. An exact name has every label of the host, so it beats any
    /// suffix, and a longer suffix beats a shorter one.
    private func policy(forHost host: String, in state: State, at date: Date) -> TLSPinPolicy {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        var best: (set: TLSPinSet, labels: Int)?
        for set in effectiveSets(in: state, at: date) {
            for domain in set.domains {
                let suffix = domain.name.lowercased()
                guard name == suffix || (domain.includeSubdomains && name.hasSuffix("." + suffix)) else { continue }
                let labels = suffix.split(separator: ".").count
                if labels > best?.labels ?? 0 { best = (set, labels) }
            }
        }
        guard let set = best?.set else { return .notPinned }
        return date >= set.expiresAt ? .expired(set) : .pinned(set)
    }

    /// Only a chain whose anchor is in the valid document's `prompt_roots` may be continued past,
    /// so a root installed on the device, as an MDM profile or a proxy does, never is.
    private func promptEligible(
        setID: String, host: String, chain: [SecCertificate], anchor: String?, in state: State
    ) -> TLSPinMismatch? {
        guard let document = state.document, clock() < document.expiresAt,
              let anchor, document.promptRoots.contains(anchor) else { return nil }
        let set = effectiveSets(in: state, at: clock()).first { $0.id == setID }
        let summaries = chain.map { TLSCertificateSummary(der: SecCertificateCopyData($0) as Data) }
        let kept = chain.count > 1 ? Array(chain.dropLast()) : chain
        return TLSPinMismatch(
            setID: setID,
            host: host,
            domains: set?.domains.map(\.name) ?? [],
            issuerOrganization: summaries.first?.issuerOrganization,
            certificates: summaries,
            acceptedSPKIs: Set(kept.compactMap(TLSSPKI.sha256Base64(of:)))
        )
    }
}
