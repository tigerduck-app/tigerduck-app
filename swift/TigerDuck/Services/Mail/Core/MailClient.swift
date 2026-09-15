#if os(iOS)
import Foundation

nonisolated enum MailClientError: Error, Equatable, Sendable {
    case authenticationFailed
    case certificateRejected
    case unreachable
    case serverBusy
    case searchUnsupported
    /// A folder's UIDVALIDITY no longer matches the value the caller's list was built from — the
    /// folder was recreated server-side and every UID in it now means something different.
    /// `MailMover` throws this before COPY/STORE touch anything (spec §8.3); the caller must
    /// refresh the folder before retrying the move or delete.
    case folderChanged
    case protocolError(String)
}

nonisolated enum MailFlag: String, Codable, Sendable {
    case seen, answered, deleted, draft
}

/// Everything School Mail asks of the server. `LiveMailClient` talks to Mail2000 through
/// SwiftMail, `DemoMailClient` serves the store-review fixture without a socket, tests use
/// `FakeMailClient`. Every error is a `MailClientError`.
///
/// Folder arguments are raw IMAP names (modified UTF-7), as `listFolders()` returns them.
protocol MailClient: Actor {
    func login(studentID: String, password: String) async throws
    func logout() async
    func listFolders() async throws -> [String]
    func status(folder: String) async throws -> MailboxStatusInfo
    /// The newest `pageSize` messages below `olderThanSequence` (nil = the newest), newest first.
    func page(folder: String, olderThanSequence: Int?, pageSize: Int) async throws -> MailFolderPage
    /// Summaries with UID ≥ `fromUID`. Implementations may return one extra message below
    /// `fromUID` (the IMAP `n:*` quirk); callers filter.
    func summaries(folder: String, fromUID: UInt32) async throws -> [MailSummary]
    /// Summaries for specific UIDs (search results beyond the loaded pages).
    func summaries(folder: String, uids: [UInt32]) async throws -> [MailSummary]
    func flags(folder: String, uids: ClosedRange<UInt32>) async throws -> [UInt32: MailFlags]
    func detail(folder: String, uid: UInt32) async throws -> MailMessageDetail
    /// `BODY.PEEK[]` — does not mark the message read.
    func rawSource(folder: String, uid: UInt32) async throws -> Data
    func attachment(folder: String, uid: UInt32, part: MailBodyPart) async throws -> Data
    /// Throws `.searchUnsupported` when the server rejects the search. Never falls back to
    /// downloading messages to search them locally — a caller that wants that behavior does it
    /// itself against already-loaded/cached mail.
    func search(folder: String, query: String) async throws -> [UInt32]
    func setFlag(_ flag: MailFlag, on: Bool, folder: String, uids: [UInt32]) async throws
    func copy(folder: String, uids: [UInt32], to target: String) async throws
    /// `UID SEARCH DELETED`, read fresh from the server every time this is called — never derived
    /// from cached flags. `MailMover` relies on this alone to decide whether EXPUNGE is safe
    /// (spec §8.3: EXPUNGE only when every `\Deleted` message in the folder is one TigerDuck
    /// flagged); a NO/BAD from the server must propagate as a thrown `MailClientError`, never
    /// silently degrade into an empty result.
    func deletedUIDs(folder: String) async throws -> Set<UInt32>
    func expunge(folder: String) async throws
    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws
    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool
    func send(_ message: Data, from sender: String, to recipients: [String]) async throws
}
#endif
