#if os(iOS)
import Foundation
@testable import TigerDuck

/// In-memory `MailClient` for tests. Configure with `update { $0.… = … }`.
actor FakeMailClient: MailClient {
    struct Message: Sendable {
        var summary: MailSummary
        var detail: MailMessageDetail?
        var raw: Data
        var attachments: [String: Data]
        var messageID: String?
    }

    var folders: [String: [Message]] = [:]
    var uidValidity: [String: UInt32] = [:]
    var loginError: MailClientError?
    var statusError: MailClientError?
    /// Simulates a `page` the server refused (e.g. unreachable partway through a session) —
    /// used to prove a caller's own state change (dropping a stale cache, say) survives even
    /// when the reload that follows it doesn't succeed.
    var pageError: MailClientError?
    var searchError: MailClientError?
    var sendError: MailClientError?
    var detailError: MailClientError?
    /// Simulates a `BODY.PEEK[]` fetch failing — used to prove the message screen's source view
    /// ends its spinner in a retryable failed state instead of spinning forever.
    var rawSourceError: MailClientError?
    /// Simulates a COPY the server refused (e.g. the target folder is gone): `MailMover` must
    /// never reach STORE afterwards.
    var copyError: MailClientError?
    /// Simulates a STORE the server refused: `MailMover` must never reach the deleted-UID check
    /// or EXPUNGE afterwards.
    var setFlagError: MailClientError?
    /// Simulates a `UID SEARCH DELETED` the server rejected (NO/BAD): `MailMover` must throw and
    /// never EXPUNGE, even though its own STORE may already have landed.
    var deletedUIDsError: MailClientError?
    var acceptedPassword: String?
    var holdStatus = false
    /// When set, `search` suspends until `releaseSearch()` is called — used to land a folder
    /// switch (or any other state change) while a search is still in flight, deterministically
    /// rather than by racing wall-clock sleeps.
    var holdSearch = false
    /// When set, `send` also files the message here, like a server that keeps sent copies.
    var autoSaveSentTo: String?
    /// Returned by `summaries(folder:fromUID:)` on top of the real range (the `n:*` quirk).
    var extraSummaries: [MailSummary] = []
    private(set) var calls: [String] = []
    private(set) var sent: [(message: Data, from: String, to: [String])] = []
    private var statusGate: CheckedContinuation<Void, Never>?
    private var searchGate: CheckedContinuation<Void, Never>?

    init(folders: [String: [Message]] = [:]) {
        self.folders = folders
    }

    func update(_ change: @Sendable (isolated FakeMailClient) -> Void) {
        change(self)
    }

    func releaseStatus() {
        holdStatus = false
        statusGate?.resume()
        statusGate = nil
    }

    func releaseSearch() {
        holdSearch = false
        searchGate?.resume()
        searchGate = nil
    }

    static func message(
        uid: UInt32,
        from: String = "office@mail.ntust.edu.tw",
        name: String? = nil,
        subject: String = "subject \(Int.random(in: 0...9))",
        seen: Bool = false,
        deleted: Bool = false,
        text: String? = "body",
        html: String? = nil,
        messageID: String? = nil
    ) -> Message {
        let summary = MailSummary(
            uid: uid, fromName: name, fromAddress: from, to: ["b10000000@mail.ntust.edu.tw"], cc: nil,
            subject: subject, date: Date(timeIntervalSince1970: 1_789_000_000 + TimeInterval(uid)),
            isSeen: seen, isAnswered: false, isDeleted: deleted, size: 100, hasAttachments: false,
            isExternal: !MailWarnings.isSchoolDomain(MailWarnings.domain(ofAddress: from))
        )
        let detail = MailMessageDetail(summary: summary, messageID: messageID, inReplyTo: nil, references: nil,
                                       parts: [], textBody: text, htmlBody: html, inlineImages: nil)
        let raw = Data("From: \(from)\r\nSubject: \(subject)\r\nMessage-ID: \(messageID ?? "<\(uid)@fake>")\r\n\r\n\(text ?? "")\r\n".utf8)
        return Message(summary: summary, detail: detail, raw: raw, attachments: [:], messageID: messageID)
    }

    // MARK: MailClient

    func login(studentID: String, password: String) async throws {
        calls.append("login \(studentID)")
        if let loginError { throw loginError }
        if let acceptedPassword, acceptedPassword != password { throw MailClientError.authenticationFailed }
    }

    func logout() async { calls.append("logout") }

    func listFolders() async throws -> [String] {
        calls.append("listFolders")
        return folders.keys.sorted()
    }

    func status(folder: String) async throws -> MailboxStatusInfo {
        calls.append("status \(folder)")
        if holdStatus { await withCheckedContinuation { statusGate = $0 } }
        if let statusError { throw statusError }
        let messages = folders[folder] ?? []
        return MailboxStatusInfo(
            uidValidity: uidValidity[folder] ?? 1,
            uidNext: (messages.map(\.summary.uid).max() ?? 0) + 1,
            unseen: messages.filter { !$0.summary.isSeen }.count
        )
    }

    func page(folder: String, olderThanSequence: Int?, pageSize: Int) async throws -> MailFolderPage {
        calls.append("page \(folder)")
        if let pageError { throw pageError }
        let ordered = (folders[folder] ?? []).sorted { $0.summary.uid < $1.summary.uid }
        let total = ordered.count
        let upper = min((olderThanSequence ?? total + 1) - 1, total)
        let lower = max(1, upper - pageSize + 1)
        let slice = upper >= 1 ? Array(ordered[(lower - 1)..<upper]) : []
        return MailFolderPage(
            folder: folder, uidValidity: uidValidity[folder] ?? 1, messageCount: total,
            summaries: Array(slice.map(\.summary).filter { !$0.isDeleted }.reversed()),
            oldestLoadedSequence: upper >= 1 && lower > 1 ? lower : nil
        )
    }

    func summaries(folder: String, fromUID: UInt32) async throws -> [MailSummary] {
        calls.append("summaries \(folder) \(fromUID)")
        return (folders[folder] ?? []).map(\.summary).filter { $0.uid >= fromUID } + extraSummaries
    }

    func summaries(folder: String, uids: [UInt32]) async throws -> [MailSummary] {
        calls.append("summaries \(folder) \(uids)")
        return (folders[folder] ?? []).map(\.summary).filter { uids.contains($0.uid) }
    }

    func flags(folder: String, uids: ClosedRange<UInt32>) async throws -> [UInt32: MailFlags] {
        calls.append("flags \(folder) \(uids)")
        var result: [UInt32: MailFlags] = [:]
        for message in folders[folder] ?? [] where uids.contains(message.summary.uid) {
            let s = message.summary
            result[s.uid] = MailFlags(seen: s.isSeen, answered: s.isAnswered, deleted: s.isDeleted)
        }
        return result
    }

    func detail(folder: String, uid: UInt32) async throws -> MailMessageDetail {
        calls.append("detail \(folder) \(uid)")
        if let detailError { throw detailError }
        guard let message = folders[folder]?.first(where: { $0.summary.uid == uid }) else {
            throw MailClientError.protocolError("no message \(uid)")
        }
        var detail = message.detail ?? MailMessageDetail(summary: message.summary, messageID: nil, inReplyTo: nil,
                                                         references: nil, parts: [], textBody: nil, htmlBody: nil, inlineImages: nil)
        detail.summary = message.summary
        return detail
    }

    func rawSource(folder: String, uid: UInt32) async throws -> Data {
        calls.append("rawSource \(folder) \(uid)")
        if let rawSourceError { throw rawSourceError }
        return folders[folder]?.first(where: { $0.summary.uid == uid })?.raw ?? Data()
    }

    func attachment(folder: String, uid: UInt32, part: MailBodyPart) async throws -> Data {
        calls.append("attachment \(uid) \(part.section)")
        return folders[folder]?.first(where: { $0.summary.uid == uid })?.attachments[part.section] ?? Data()
    }

    func search(folder: String, query: String) async throws -> [UInt32] {
        calls.append("search \(folder) \(query)")
        if holdSearch { await withCheckedContinuation { searchGate = $0 } }
        if let searchError { throw searchError }
        return (folders[folder] ?? []).map(\.summary).filter {
            ($0.subject ?? "").localizedCaseInsensitiveContains(query)
                || ($0.fromAddress ?? "").localizedCaseInsensitiveContains(query)
        }.map(\.uid)
    }

    func setFlag(_ flag: MailFlag, on: Bool, folder: String, uids: [UInt32]) async throws {
        calls.append("setFlag \(flag.rawValue) \(on) \(uids)")
        if let setFlagError { throw setFlagError }
        guard var messages = folders[folder] else { return }
        for index in messages.indices where uids.contains(messages[index].summary.uid) {
            switch flag {
            case .seen: messages[index].summary.isSeen = on
            case .answered: messages[index].summary.isAnswered = on
            case .deleted: messages[index].summary.isDeleted = on
            case .draft: break
            }
        }
        folders[folder] = messages
    }

    func copy(folder: String, uids: [UInt32], to target: String) async throws {
        calls.append("copy \(uids) \(target)")
        if let copyError { throw copyError }
        var destination = folders[target] ?? []
        var next = (destination.map(\.summary.uid).max() ?? 0) + 1
        for message in (folders[folder] ?? []) where uids.contains(message.summary.uid) {
            var copy = message
            copy.summary.uid = next
            copy.summary.isDeleted = false
            destination.append(copy)
            next += 1
        }
        folders[target] = destination
    }

    func deletedUIDs(folder: String) async throws -> Set<UInt32> {
        calls.append("deletedUIDs \(folder)")
        if let deletedUIDsError { throw deletedUIDsError }
        return Set((folders[folder] ?? []).filter(\.summary.isDeleted).map(\.summary.uid))
    }

    func expunge(folder: String) async throws {
        calls.append("expunge \(folder)")
        folders[folder]?.removeAll { $0.summary.isDeleted }
    }

    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws {
        calls.append("append \(folder) \(flags.map(\.rawValue))")
        var messages = folders[folder] ?? []
        let uid = (messages.map(\.summary.uid).max() ?? 0) + 1
        var appended = Self.message(uid: uid, seen: flags.contains(.seen), messageID: MailRawHeaders.value(named: "Message-ID", in: message))
        appended.raw = message
        messages.append(appended)
        folders[folder] = messages
    }

    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool {
        calls.append("containsMessageID \(folder)")
        return (folders[folder] ?? []).contains { $0.messageID == messageID }
    }

    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        calls.append("send")
        if let sendError { throw sendError }
        sent.append((message, sender, recipients))
        if let autoSaveSentTo {
            var messages = folders[autoSaveSentTo] ?? []
            var copy = Self.message(uid: (messages.map(\.summary.uid).max() ?? 0) + 1, seen: true,
                                    messageID: MailRawHeaders.value(named: "Message-ID", in: message))
            copy.raw = message
            messages.append(copy)
            folders[autoSaveSentTo] = messages
        }
    }
}
#endif
