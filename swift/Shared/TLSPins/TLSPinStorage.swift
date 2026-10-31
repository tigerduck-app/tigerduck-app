import CryptoKit
import Foundation
import os

/// The signed document and this build's acceptances as `TLSPinEngine` keeps them in Defaults.
nonisolated struct TLSPinStorage {
    private enum Key {
        static let document = "tlsPinDocumentEnvelope"
        static let acceptances = "tlsPinAcceptances"
    }

    let defaults: UserDefaults
    let keys: [String: Curve25519.Signing.PublicKey]
    let buildNumber: String
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Security.TLSPin")

    init(defaults: UserDefaults, keys: [String: Curve25519.Signing.PublicKey], buildNumber: String) {
        self.defaults = defaults
        self.keys = keys
        self.buildNumber = buildNumber
    }

    /// Verified again because this build may trust other signing keys than the build that stored it.
    func storedDocument() -> TLSPinDocument? {
        guard let envelope = defaults.data(forKey: Key.document) else { return nil }
        let document = try? TLSPinDocument.verify(envelope: envelope, keys: keys)
        if document == nil {
            logger.error("Stored TLS pin document failed verification; dropped")
            defaults.removeObject(forKey: Key.document)
        }
        return document
    }

    /// This build's acceptances; those of another build are dropped from the store.
    func storedAcceptances() -> [TLSPinAcceptance] {
        guard let data = defaults.data(forKey: Key.acceptances),
              let stored = try? JSONDecoder().decode([TLSPinAcceptance].self, from: data) else { return [] }
        let current = stored.filter { $0.buildNumber == buildNumber }
        if current.count != stored.count { persist(current) }
        return current
    }

    func saveDocument(_ envelope: Data) {
        defaults.set(envelope, forKey: Key.document)
    }

    func persist(_ acceptances: [TLSPinAcceptance]) {
        if let data = try? JSONEncoder().encode(acceptances) {
            defaults.set(data, forKey: Key.acceptances)
        }
    }
}
