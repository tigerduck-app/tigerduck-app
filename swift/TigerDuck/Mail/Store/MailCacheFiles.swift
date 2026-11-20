#if os(iOS)
import Foundation
import os

nonisolated struct MailCacheFiles: Sendable {
    static let formatVersion = 1

    private struct Envelope<Payload: Codable>: Codable {
        var version: Int
        var payload: Payload
        var account: String?
    }

    let directory: URL
    let account: @Sendable () -> String?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.Cache")

    init(directory: URL, account: @escaping @Sendable () -> String?) {
        self.directory = directory
        self.account = account
    }

    func read<T: Codable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let value = decoded(type, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return value
    }

    func decoded<T: Codable>(_ type: T.Type, from data: Data) -> T? {
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data),
              envelope.version == Self.formatVersion,
              envelope.account == account() else { return nil }
        return envelope.payload
    }

    func encoded<T: Codable>(_ value: T) -> Data? {
        let envelope = Envelope(version: Self.formatVersion, payload: value, account: account())
        guard let data = try? JSONEncoder().encode(envelope) else {
            logger.error("Mail cache encode failed, dropping write")
            return nil
        }
        return data
    }

    func persist(_ data: Data, to url: URL) {
        do {
            try createDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("Mail cache write failed, dropping write: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        Self.excludeFromBackup(directory)
    }

    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try? url.setResourceValues(values)
    }

    func noteEntryTooLarge() {
        logger.notice("Mail cache entry larger than half the body budget, not cached")
    }
}
#endif
