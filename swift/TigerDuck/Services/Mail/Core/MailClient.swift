#if os(iOS)
import Foundation

nonisolated enum MailClientError: Error, Equatable, Sendable {
    case authenticationFailed
    case certificateRejected
    case unreachable
    case serverBusy
    case searchUnsupported
    case folderChanged
    case sendUnconfirmed
    case protocolError(String)
}

nonisolated enum MailFlag: String, Codable, Sendable {
    case seen, answered, deleted, draft
}

protocol MailClient: Actor {
    func login(studentID: String, password: String) async throws
    func logout() async
    func listFolders() async throws -> [String]
    func status(folder: String) async throws -> MailboxStatusInfo
    func page(folder: String, olderThanSequence: Int?, pageSize: Int) async throws -> MailFolderPage
    /// Summaries with UID ≥ `fromUID`. Implementations may return one extra message below
    /// `fromUID` (the IMAP `n:*` quirk); callers filter.
    func summaries(folder: String, fromUID: UInt32) async throws -> [MailSummary]
    func summaries(folder: String, uids: [UInt32], expectedUIDValidity: UInt32?) async throws -> [MailSummary]
    func flags(folder: String, uids: ClosedRange<UInt32>, expectedUIDValidity: UInt32?) async throws -> [UInt32: MailFlags]
    func detail(folder: String, uid: UInt32, expectedUIDValidity: UInt32?, inlineImages: Bool) async throws -> MailMessageDetail
    func rawSource(folder: String, uid: UInt32, expectedUIDValidity: UInt32?) async throws -> Data
    func attachment(folder: String, uid: UInt32, part: MailBodyPart, expectedUIDValidity: UInt32?) async throws -> Data
    func search(folder: String, query: String) async throws -> (uids: [UInt32], uidValidity: UInt32)
    func setFlag(_ flag: MailFlag, on: Bool, folder: String, uids: [UInt32], expectedUIDValidity: UInt32?) async throws
    func copy(folder: String, uids: [UInt32], to target: String, expectedUIDValidity: UInt32) async throws
    func deletedUIDs(folder: String, expectedUIDValidity: UInt32) async throws -> Set<UInt32>
    func expunge(folder: String, expectedUIDValidity: UInt32) async throws
    func createFolder(_ name: String) async throws
    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws
    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool
    func send(_ message: Data, from sender: String, to recipients: [String]) async throws
}

extension MailClient {
    func detail(folder: String, uid: UInt32, expectedUIDValidity: UInt32?) async throws -> MailMessageDetail {
        try await detail(folder: folder, uid: uid, expectedUIDValidity: expectedUIDValidity, inlineImages: true)
    }
}
#endif
