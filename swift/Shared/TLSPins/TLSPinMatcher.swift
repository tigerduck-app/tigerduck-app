import Foundation
import Security

nonisolated struct TLSPinMatcher {
    let builtIn: [TLSPinSet]
    let baselineSerial: Int64

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

    static func listsPromptRoot(_ anchor: String, document: TLSPinDocument?, at date: Date) -> Bool {
        guard let document, date < document.expiresAt else { return false }
        return document.promptRoots.contains(anchor)
    }

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
