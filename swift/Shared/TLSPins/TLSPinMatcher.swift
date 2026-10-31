import Foundation
import Security

/// The pins in force for a host: the built-in table, a newer signed document over it and the
/// user's acceptances, matched against host names.
nonisolated struct TLSPinMatcher {
    let builtIn: [TLSPinSet]
    let baselineSerial: Int64

    /// The sets the document replaces, when it is newer than the built-in table; a set it does not
    /// list keeps the built-in pins, and an expiry it moves earlier is ignored.
    func effectiveSets(document: TLSPinDocument?, acceptances: [TLSPinAcceptance], at date: Date) -> [TLSPinSet] {
        let document = document.flatMap { $0.serial > baselineSerial && date < $0.expiresAt ? $0 : nil }
        return builtIn.map { local in
            let remote = document?.pinSets.first { $0.id == local.id }
            let accepted = acceptances.filter { $0.setID == local.id }.flatMap(\.spkis)
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
    func policy(forHost host: String, document: TLSPinDocument?, acceptances: [TLSPinAcceptance],
                at date: Date) -> TLSPinPolicy {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        var best: (set: TLSPinSet, labels: Int)?
        for set in effectiveSets(document: document, acceptances: acceptances, at: date) {
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
    static func listsPromptRoot(_ anchor: String, document: TLSPinDocument?, at date: Date) -> Bool {
        guard let document, date < document.expiresAt else { return false }
        return document.promptRoots.contains(anchor)
    }

    /// A chain of one certificate is its own anchor, so it never gets a prompt: an acceptance holds
    /// no anchor. Nor does one whose leaf and intermediates have no key `TLSSPKI` reads, as
    /// Continue would store nothing.
    func promptEligible(
        setID: String, host: String, chain: [SecCertificate], anchor: String?,
        document: TLSPinDocument?, acceptances: [TLSPinAcceptance], at date: Date
    ) -> TLSPinMismatch? {
        let accepted = Set(chain.dropLast().compactMap(TLSSPKI.sha256Base64(of:)))
        guard chain.count > 1, !accepted.isEmpty, let anchor,
              Self.listsPromptRoot(anchor, document: document, at: date) else { return nil }
        let set = effectiveSets(document: document, acceptances: acceptances, at: date).first { $0.id == setID }
        let summaries = chain.map { TLSCertificateSummary(der: SecCertificateCopyData($0) as Data) }
        return TLSPinMismatch(
            setID: setID,
            host: host,
            domains: set?.domains.map(\.name) ?? [],
            issuerOrganization: summaries.first?.issuerOrganization,
            certificates: summaries,
            acceptedSPKIs: accepted,
            anchorSPKI: anchor,
            chainSPKIs: Set(chain.compactMap(TLSSPKI.sha256Base64(of:)))
        )
    }
}
