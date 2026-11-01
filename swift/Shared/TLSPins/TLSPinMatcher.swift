import Foundation
import Security

nonisolated struct TLSPinMatcher {
    let builtIn: [TLSPinSet]
    let baselineSerial: Int64

    func effectiveSets(document: TLSPinDocument?, acceptances: [TLSPinAcceptance], at date: Date) -> [TLSPinSet] {
        let newerDocument = document.flatMap { $0.serial > baselineSerial && date < $0.expiresAt ? $0 : nil }
        return builtIn.map { builtInSet in
            let accepted = acceptances.filter { $0.setID == builtInSet.id }.flatMap(\.spkis)
            return builtInSet
                .replaced(byDocumentSet: newerDocument?.pinSets.first { $0.id == builtInSet.id })
                .adding(accepted)
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
        let keysBelowAnchor = Set(chain.dropLast().compactMap(TLSSPKI.sha256Base64(of:)))
        guard !keysBelowAnchor.isEmpty, let anchor,
              Self.listsPromptRoot(anchor, document: document, at: date) else { return nil }
        let set = effectiveSets(document: document, acceptances: acceptances, at: date).first { $0.id == setID }
        let summaries = chain.map { TLSCertificateSummary(der: SecCertificateCopyData($0) as Data) }
        return TLSPinMismatch(
            setID: setID,
            host: host,
            domains: set?.domains.map(\.name) ?? [],
            issuerOrganization: summaries.first?.issuerOrganization,
            certificates: summaries,
            acceptedSPKIs: keysBelowAnchor,
            anchorSPKI: anchor,
            chainSPKIs: Set(chain.compactMap(TLSSPKI.sha256Base64(of:)))
        )
    }
}
