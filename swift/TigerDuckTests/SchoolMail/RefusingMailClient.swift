#if os(iOS)
import Foundation
@testable import TigerDuck

/// What `MailClientFactory` hands the unit tests in place of `LiveMailClient`: every command fails
/// the test and throws before anything connects. `logout()` does nothing, as there is nothing to
/// close; `LiveMailClient`'s would connect to send LOGOUT.
actor RefusingMailClient: MailClient {
    static let seam = "School Mail client"

    private func refuse() -> URLError {
        SchoolNetworkGuard.refusal(.init(seam: Self.seam, target: "IMAP \(MailServerConfig.effective.imapHost)"))
    }

    func login(studentID: String, password: String) async throws { throw refuse() }
    func logout() async {}
    func listFolders() async throws -> [String] { throw refuse() }
    func status(folder: String) async throws -> MailboxStatusInfo { throw refuse() }
    func page(folder: String, olderThanSequence: Int?, pageSize: Int) async throws -> MailFolderPage { throw refuse() }
    func summaries(folder: String, fromUID: UInt32) async throws -> [MailSummary] { throw refuse() }
    func summaries(folder: String, uids: [UInt32], expectedUIDValidity: UInt32?) async throws -> [MailSummary] {
        throw refuse()
    }
    func flags(
        folder: String, uids: ClosedRange<UInt32>, expectedUIDValidity: UInt32?
    ) async throws -> [UInt32: MailFlags] { throw refuse() }
    func detail(
        folder: String, uid: UInt32, expectedUIDValidity: UInt32?, inlineImages: Bool
    ) async throws -> MailMessageDetail { throw refuse() }
    func rawSource(folder: String, uid: UInt32, expectedUIDValidity: UInt32?) async throws -> Data { throw refuse() }
    func attachment(
        folder: String, uid: UInt32, part: MailBodyPart, expectedUIDValidity: UInt32?
    ) async throws -> Data { throw refuse() }
    func search(folder: String, query: String) async throws -> (uids: [UInt32], uidValidity: UInt32) {
        throw refuse()
    }
    func setFlag(
        _ flag: MailFlag, on: Bool, folder: String, uids: [UInt32], expectedUIDValidity: UInt32?
    ) async throws { throw refuse() }
    func copy(folder: String, uids: [UInt32], to target: String, expectedUIDValidity: UInt32) async throws {
        throw refuse()
    }
    func deletedUIDs(folder: String, expectedUIDValidity: UInt32) async throws -> Set<UInt32> { throw refuse() }
    func expunge(folder: String, expectedUIDValidity: UInt32) async throws { throw refuse() }
    func createFolder(_ name: String) async throws { throw refuse() }
    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws { throw refuse() }
    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool { throw refuse() }
    func send(_ message: Data, from sender: String, to recipients: [String]) async throws { throw refuse() }
}
#endif
