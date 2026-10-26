#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

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
    var uidNext: [String: UInt32] = [:]
    var loginError: MailClientError?
    var statusError: MailClientError?
    var statusErrors: [String: MailClientError] = [:]
    var pageError: MailClientError?
    var pageErrors: [String: MailClientError] = [:]
    private(set) var pageRequests: [String] = []
    var summariesError: MailClientError?
    var searchTextsError: MailClientError?
    /// Mails whose text never arrives: a batch holding one fails as an unreadable answer would.
    var searchTextsFailingUIDs: Set<UInt32> = []
    /// Simulates a server that refuses `SEARCH HEADER "Message-ID"` — nothing in Mail2000's
    /// CAPABILITY banner promises it is honoured, and a refusal is what makes the sent-copy
    /// dedupe probe unanswerable.
    var containsMessageIDError: MailClientError?
    var appendError: MailClientError?
    var sendError: MailClientError?
    var detailError: MailClientError?
    var rawSourceError: MailClientError?
    var copyError: MailClientError?
    var setFlagError: MailClientError?
    var deletedUIDsError: MailClientError?
    var createFolderError: MailClientError?
    var createdFolderName: String?
    var listFoldersError: MailClientError?
    var acceptedPassword: String?
    var holdStatus: Bool {
        get { heldCommands.contains("status") }
        set { if newValue { heldCommands.insert("status") } else { heldCommands.remove("status") } }
    }
    var autoSaveSentTo: String?
    /// Returned by `summaries(folder:fromUID:)` on top of the real range (the `n:*` quirk).
    var extraSummaries: [MailSummary] = []
    private(set) var calls: [String] = []
    private(set) var attachmentPins: [UInt32?] = []
    private(set) var detailsWithoutImages: [UInt32] = []
    private(set) var sent: [(message: Data, from: String, to: [String])] = []
    private var heldCommands: Set<String> = []
    private var releaseGates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var arrivedCommands: Set<String> = []

    init(folders: [String: [Message]] = [:]) {
        self.folders = folders
    }

    func update(_ change: @Sendable (isolated FakeMailClient) -> Void) {
        change(self)
    }

    func hold(_ command: String) {
        heldCommands.insert(command)
    }

    func release(_ command: String) {
        heldCommands.remove(command)
        for gate in releaseGates.removeValue(forKey: command) ?? [] { gate.resume() }
    }

    func waitForArrival(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        try? await waitUntil({ arrivedCommands.contains(command) }, sourceLocation: sourceLocation)
    }

    private func gate(_ command: String) async {
        arrivedCommands.insert(command)
        guard heldCommands.contains(command) else { return }
        await withCheckedContinuation { releaseGates[command, default: []].append($0) }
    }

    func releaseStatus() {
        release("status")
    }

    private func assertUIDValidity(_ expected: UInt32?, folder: String) throws {
        try LiveMailClient.assertUIDValidity(expected: expected, current: uidValidity[folder] ?? 1)
    }

    static func message(
        uid: UInt32,
        from: String = "office@mail.ntust.edu.tw",
        name: String? = nil,
        subject: String? = nil,
        seen: Bool = false,
        deleted: Bool = false,
        text: String? = "body",
        html: String? = nil,
        messageID: String? = nil,
        returnPath: String? = nil,
        replyTo: String? = nil
    ) -> Message {
        let subject = subject ?? "subject \(uid)"
        let address = from.mailNonEmpty
        let summary = MailSummary(
            uid: uid, fromName: name, fromAddress: address, to: ["b10000000@mail.ntust.edu.tw"], cc: nil,
            subject: subject, date: Date(timeIntervalSince1970: 1_789_000_000 + TimeInterval(uid)),
            isSeen: seen, isAnswered: false, isDeleted: deleted, size: 100, hasAttachments: false,
            isExternal: address.map { !MailWarnings.isSchoolDomain(MailWarnings.domain(ofAddress: $0)) } ?? false
        )
        let detail = MailMessageDetail(summary: summary, messageID: messageID, inReplyTo: nil, references: nil,
                                       returnPath: returnPath, replyTo: replyTo,
                                       parts: [], textBody: text, htmlBody: html, inlineImages: nil)
        let raw = Data("From: \(from)\r\nSubject: \(subject)\r\nMessage-ID: \(messageID ?? "<\(uid)@fake>")\r\n\r\n\(text ?? "")\r\n".utf8)
        return Message(summary: summary, detail: detail, raw: raw, attachments: [:], messageID: messageID)
    }

    func login(studentID: String, password: String) async throws {
        calls.append("login \(studentID)")
        await gate("login")
        if let loginError { throw loginError }
        if let acceptedPassword, acceptedPassword != password { throw MailClientError.authenticationFailed }
    }

    func logout() async {
        calls.append("logout")
        await gate("logout")
    }

    func listFolders() async throws -> [String] {
        calls.append("listFolders")
        if let listFoldersError { throw listFoldersError }
        return folders.keys.sorted()
    }

    func status(folder: String) async throws -> MailboxStatusInfo {
        calls.append("status \(folder)")
        await gate("status")
        if let statusError { throw statusError }
        if let error = statusErrors[folder] { throw error }
        return MailboxStatusInfo(uidValidity: uidValidity[folder] ?? 1, uidNext: nextUID(folder))
    }

    private func nextUID(_ folder: String) -> UInt32 {
        uidNext[folder] ?? ((folders[folder] ?? []).map(\.summary.uid).max() ?? 0) + 1
    }

    func page(folder: String, olderThanSequence: Int?, pageSize: Int) async throws -> MailFolderPage {
        calls.append("page \(folder)")
        pageRequests.append("\(folder) \(pageSize)")
        await gate("page")
        if let pageError { throw pageError }
        if let error = pageErrors[folder] { throw error }
        let ordered = (folders[folder] ?? []).sorted { $0.summary.uid < $1.summary.uid }
        let total = ordered.count
        let upper = min((olderThanSequence ?? total + 1) - 1, total)
        let lower = max(1, upper - pageSize + 1)
        let slice = upper >= 1 ? Array(ordered[(lower - 1)..<upper]) : []
        return MailFolderPage(
            folder: folder, uidValidity: uidValidity[folder] ?? 1, messageCount: total,
            summaries: Array(slice.map(\.summary).filter { !$0.isDeleted }.reversed()),
            oldestLoadedSequence: upper >= 1 && lower > 1 ? lower : nil,
            uidNext: nextUID(folder),
            windowUIDs: MailFolderPage.span(of: slice.map(\.summary.uid))
        )
    }

    func summaries(folder: String, fromUID: UInt32) async throws -> [MailSummary] {
        calls.append("summaries \(folder) \(fromUID)")
        return (folders[folder] ?? []).map(\.summary).filter { $0.uid >= fromUID } + extraSummaries
    }

    func summaries(folder: String, uids: [UInt32], expectedUIDValidity: UInt32?) async throws -> [MailSummary] {
        calls.append("summaries \(folder) \(uids)")
        await gate("summaries")
        if let summariesError { throw summariesError }
        try assertUIDValidity(expectedUIDValidity, folder: folder)
        return (folders[folder] ?? []).map(\.summary).filter { uids.contains($0.uid) }
    }

    func flags(folder: String, uids: ClosedRange<UInt32>, expectedUIDValidity: UInt32?) async throws -> [UInt32: MailFlags] {
        calls.append("flags \(folder) \(uids)")
        await gate("flags")
        try assertUIDValidity(expectedUIDValidity, folder: folder)
        var result: [UInt32: MailFlags] = [:]
        for message in folders[folder] ?? [] where uids.contains(message.summary.uid) {
            let s = message.summary
            result[s.uid] = MailFlags(seen: s.isSeen, answered: s.isAnswered, deleted: s.isDeleted)
        }
        return result
    }

    func detail(folder: String, uid: UInt32, expectedUIDValidity: UInt32?, inlineImages: Bool) async throws -> MailMessageDetail {
        calls.append("detail \(folder) \(uid)")
        if !inlineImages { detailsWithoutImages.append(uid) }
        await gate("detail")
        if let detailError { throw detailError }
        try assertUIDValidity(expectedUIDValidity, folder: folder)
        guard let message = folders[folder]?.first(where: { $0.summary.uid == uid }) else {
            throw MailClientError.protocolError("no message \(uid)")
        }
        var detail = message.detail ?? MailMessageDetail(summary: message.summary, messageID: nil, inReplyTo: nil,
                                                         references: nil, parts: [], textBody: nil, htmlBody: nil, inlineImages: nil)
        detail.summary = message.summary
        return detail
    }

    func rawSource(folder: String, uid: UInt32, expectedUIDValidity: UInt32?) async throws -> Data {
        calls.append("rawSource \(folder) \(uid)")
        await gate("rawSource")
        if let rawSourceError { throw rawSourceError }
        try assertUIDValidity(expectedUIDValidity, folder: folder)
        return folders[folder]?.first(where: { $0.summary.uid == uid })?.raw ?? Data()
    }

    func attachment(folder: String, uid: UInt32, part: MailBodyPart, expectedUIDValidity: UInt32?) async throws -> Data {
        calls.append("attachment \(uid) \(part.section)")
        attachmentPins.append(expectedUIDValidity)
        await gate("attachment")
        try assertUIDValidity(expectedUIDValidity, folder: folder)
        return folders[folder]?.first(where: { $0.summary.uid == uid })?.attachments[part.section] ?? Data()
    }

    func undeletedUIDs(folder: String) async throws -> (uids: [UInt32], uidValidity: UInt32) {
        calls.append("undeletedUIDs \(folder)")
        await gate("undeletedUIDs")
        return ((folders[folder] ?? []).map(\.summary).filter { !$0.isDeleted }.map(\.uid), uidValidity[folder] ?? 1)
    }

    func searchTexts(folder: String, uids: [UInt32], expectedUIDValidity: UInt32) async throws -> [UInt32: String] {
        calls.append("searchTexts \(folder) \(uids)")
        await gate("searchTexts")
        if let searchTextsError { throw searchTextsError }
        if !searchTextsFailingUIDs.isDisjoint(with: uids) { throw MailClientError.protocolError("unreadable") }
        try assertUIDValidity(expectedUIDValidity, folder: folder)
        var texts: [UInt32: String] = [:]
        for message in folders[folder] ?? [] where uids.contains(message.summary.uid) && !message.summary.isDeleted {
            texts[message.summary.uid] = MailSearchIndex.text(of: message.summary, body: message.detail?.textBody)
        }
        return texts
    }

    func setFlag(_ flag: MailFlag, on: Bool, folder: String, uids: [UInt32], expectedUIDValidity: UInt32?) async throws {
        calls.append("setFlag \(flag.rawValue) \(on) \(uids)")
        await gate("setFlag")
        if let setFlagError { throw setFlagError }
        try assertUIDValidity(expectedUIDValidity, folder: folder)
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

    func copy(folder: String, uids: [UInt32], to target: String, expectedUIDValidity: UInt32) async throws {
        calls.append("copy \(uids) \(target)")
        await gate("copy")
        if let copyError { throw copyError }
        try assertUIDValidity(expectedUIDValidity, folder: folder)
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

    func deletedUIDs(folder: String, expectedUIDValidity: UInt32) async throws -> Set<UInt32> {
        calls.append("deletedUIDs \(folder)")
        await gate("deletedUIDs")
        if let deletedUIDsError { throw deletedUIDsError }
        try assertUIDValidity(expectedUIDValidity, folder: folder)
        return Set((folders[folder] ?? []).filter(\.summary.isDeleted).map(\.summary.uid))
    }

    func expunge(folder: String, expectedUIDValidity: UInt32) async throws {
        calls.append("expunge \(folder)")
        await gate("expunge")
        try assertUIDValidity(expectedUIDValidity, folder: folder)
        folders[folder]?.removeAll { $0.summary.isDeleted }
    }

    func createFolder(_ name: String) async throws {
        calls.append("createFolder \(name)")
        await gate("createFolder")
        if let createFolderError { throw createFolderError }
        let stored = createdFolderName ?? name
        guard folders[stored] == nil else { throw MailClientError.protocolError("mailbox already exists") }
        folders[stored] = []
    }

    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws {
        calls.append("append \(folder) \(flags.map(\.rawValue))")
        await gate("append")
        if let appendError { throw appendError }
        var messages = folders[folder] ?? []
        let uid = (messages.map(\.summary.uid).max() ?? 0) + 1
        var appended = Self.message(uid: uid, seen: flags.contains(.seen), messageID: MailRawHeaders.value(named: "Message-ID", in: message))
        appended.raw = message
        messages.append(appended)
        folders[folder] = messages
    }

    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool {
        calls.append("containsMessageID \(folder)")
        if let containsMessageIDError { throw containsMessageIDError }
        return (folders[folder] ?? []).contains { $0.messageID == messageID }
    }

    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        calls.append("send")
        await gate("send")
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
