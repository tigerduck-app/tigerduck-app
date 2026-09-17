#if os(iOS)
import Foundation

/// The store-review mailbox (`mail-demo.json`). Made-up data; no real student.
nonisolated struct MailDemoFixture: Decodable, Sendable {
    struct Attachment: Decodable, Sendable {
        var filename: String
        var contentType: String
        var base64: String
    }

    struct Entry: Decodable, Sendable {
        var uid: UInt32
        var fromName: String?
        var fromAddress: String
        var to: [String]
        var subject: String
        var date: Date
        var seen: Bool
        var text: String
        var html: String?
        var attachments: [Attachment]
    }

    var studentId: String
    var password: String
    var uidValidity: UInt32
    var folders: [String: [Entry]]

    static let shared: MailDemoFixture? = load(from: .main)

    static func load(from bundle: Bundle) -> MailDemoFixture? {
        guard let url = bundle.url(forResource: "mail-demo", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MailDemoFixture.self, from: data)
    }

    func matches(studentID: String, password: String) -> Bool {
        studentID.caseInsensitiveCompare(studentId) == .orderedSame && password == self.password
    }
}

/// `MailClient` over the demo fixture. Never opens a socket (design doc §7.6). State lives
/// for the app's lifetime so read/move actions stick while a reviewer explores.
actor DemoMailClient: MailClient {
    static let shared: DemoMailClient? = MailDemoFixture.shared.map { DemoMailClient(fixture: $0) }

    private struct Stored: Sendable {
        var summary: MailSummary
        var text: String
        var html: String?
        var attachments: [MailBodyPart: Data]
    }

    private let fixture: MailDemoFixture
    private var folders: [String: [Stored]]

    init(fixture: MailDemoFixture) {
        self.fixture = fixture
        folders = fixture.folders.mapValues { entries in entries.map(Self.stored(from:)) }
    }

    private static func stored(from entry: MailDemoFixture.Entry) -> Stored {
        var attachments: [MailBodyPart: Data] = [:]
        for (index, attachment) in entry.attachments.enumerated() {
            let part = MailBodyPart(section: "\(index + 2)", contentType: attachment.contentType, charset: nil,
                                    transferEncoding: "base64", filename: attachment.filename, contentID: nil,
                                    size: attachment.base64.count * 3 / 4, isAttachment: true)
            attachments[part] = Data(base64Encoded: attachment.base64) ?? Data()
        }
        let summary = MailSummary(
            uid: entry.uid, fromName: entry.fromName?.mailNonEmpty, fromAddress: entry.fromAddress, to: entry.to, cc: nil,
            subject: entry.subject, date: entry.date, isSeen: entry.seen, isAnswered: false, isDeleted: false,
            size: entry.text.utf8.count, hasAttachments: !attachments.isEmpty,
            isExternal: !MailWarnings.isSchoolDomain(MailWarnings.domain(ofAddress: entry.fromAddress))
        )
        return Stored(summary: summary, text: entry.text, html: entry.html, attachments: attachments)
    }

    func login(studentID: String, password: String) async throws {
        guard fixture.matches(studentID: studentID, password: password) else { throw MailClientError.authenticationFailed }
    }

    func logout() async {}

    func listFolders() async throws -> [String] { folders.keys.sorted() }

    func status(folder: String) async throws -> MailboxStatusInfo {
        let messages = folders[folder] ?? []
        return MailboxStatusInfo(uidValidity: fixture.uidValidity,
                                 uidNext: (messages.map(\.summary.uid).max() ?? 0) + 1,
                                 unseen: messages.filter { !$0.summary.isSeen }.count)
    }

    func page(folder: String, olderThanSequence: Int?, pageSize: Int) async throws -> MailFolderPage {
        let ordered = (folders[folder] ?? []).sorted { $0.summary.uid < $1.summary.uid }
        let total = ordered.count
        let upper = min((olderThanSequence ?? total + 1) - 1, total)
        let lower = max(1, upper - pageSize + 1)
        let slice = upper >= 1 ? Array(ordered[(lower - 1)..<upper]) : []
        return MailFolderPage(folder: folder, uidValidity: fixture.uidValidity, messageCount: total,
                              summaries: Array(slice.map(\.summary).filter { !$0.isDeleted }.reversed()),
                              oldestLoadedSequence: upper >= 1 && lower > 1 ? lower : nil)
    }

    func summaries(folder: String, fromUID: UInt32) async throws -> [MailSummary] {
        (folders[folder] ?? []).map(\.summary).filter { $0.uid >= fromUID }
    }

    func summaries(folder: String, uids: [UInt32]) async throws -> [MailSummary] {
        (folders[folder] ?? []).map(\.summary).filter { uids.contains($0.uid) }
    }

    func flags(folder: String, uids: ClosedRange<UInt32>) async throws -> [UInt32: MailFlags] {
        var result: [UInt32: MailFlags] = [:]
        for stored in folders[folder] ?? [] where uids.contains(stored.summary.uid) {
            let s = stored.summary
            result[s.uid] = MailFlags(seen: s.isSeen, answered: s.isAnswered, deleted: s.isDeleted)
        }
        return result
    }

    func detail(folder: String, uid: UInt32) async throws -> MailMessageDetail {
        let stored = try find(folder: folder, uid: uid)
        var parts = [MailBodyPart(section: "1", contentType: "text/plain", charset: "utf-8", transferEncoding: "8bit",
                                  filename: nil, contentID: nil, size: stored.text.utf8.count, isAttachment: false)]
        parts += stored.attachments.keys.sorted { $0.section < $1.section }
        return MailMessageDetail(summary: stored.summary, messageID: "<demo-\(uid)@\(MailConstants.addressDomain)>",
                                 inReplyTo: nil, references: nil, parts: parts, textBody: stored.text,
                                 htmlBody: stored.html, inlineImages: nil)
    }

    func rawSource(folder: String, uid: UInt32) async throws -> Data {
        let stored = try find(folder: folder, uid: uid)
        let mail = OutgoingMail(
            from: MailAddress(name: stored.summary.fromName, address: stored.summary.fromAddress ?? ""),
            to: (stored.summary.to ?? []).map { MailAddress(name: nil, address: $0) }, cc: [], bcc: [],
            subject: stored.summary.subject ?? "", body: stored.text, inReplyTo: nil, references: [],
            attachments: stored.attachments.map { OutgoingAttachment(filename: $0.key.filename ?? "file", mimeType: $0.key.contentType, data: $0.value) }
        )
        return MailMessageBuilder.build(mail, messageID: "<demo-\(uid)@\(MailConstants.addressDomain)>",
                                        date: stored.summary.date ?? Date(), boundary: "demo-\(uid)")
    }

    func attachment(folder: String, uid: UInt32, part: MailBodyPart) async throws -> Data {
        let stored = try find(folder: folder, uid: uid)
        return stored.attachments.first { $0.key.section == part.section }?.value ?? Data()
    }

    func search(folder: String, query: String) async throws -> [UInt32] {
        (folders[folder] ?? []).filter {
            ($0.summary.subject ?? "").localizedCaseInsensitiveContains(query)
                || ($0.summary.fromAddress ?? "").localizedCaseInsensitiveContains(query)
                || ($0.summary.fromName ?? "").localizedCaseInsensitiveContains(query)
                || $0.text.localizedCaseInsensitiveContains(query)
        }.map(\.summary.uid)
    }

    func setFlag(_ flag: MailFlag, on: Bool, folder: String, uids: [UInt32]) async throws {
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
        var destination = folders[target] ?? []
        var next = (destination.map(\.summary.uid).max() ?? 0) + 1
        for stored in folders[folder] ?? [] where uids.contains(stored.summary.uid) {
            var copy = stored
            copy.summary.uid = next
            copy.summary.isDeleted = false
            destination.append(copy)
            next += 1
        }
        folders[target] = destination
    }

    func deletedUIDs(folder: String) async throws -> Set<UInt32> {
        Set((folders[folder] ?? []).filter(\.summary.isDeleted).map(\.summary.uid))
    }

    func expunge(folder: String) async throws {
        folders[folder]?.removeAll { $0.summary.isDeleted }
    }

    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws {
        var messages = folders[folder] ?? []
        let uid = (messages.map(\.summary.uid).max() ?? 0) + 1
        let from = MailRawHeaders.value(named: "From", in: message).flatMap { MailAddress.parseList($0).first }
        let summary = MailSummary(
            uid: uid, fromName: from?.name, fromAddress: from?.address, to: nil, cc: nil,
            subject: MailRawHeaders.value(named: "Subject", in: message), date: Date(),
            isSeen: flags.contains(.seen), isAnswered: false, isDeleted: false, size: message.count,
            hasAttachments: false, isExternal: false
        )
        let body = String(decoding: message, as: UTF8.self).components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        messages.append(Stored(summary: summary, text: body, html: nil, attachments: [:]))
        folders[folder] = messages
    }

    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool { false }

    /// The demo never sends anything; compose then saves the copy into 寄件備份匣 itself.
    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {}

    private func find(folder: String, uid: UInt32) throws -> Stored {
        guard let stored = folders[folder]?.first(where: { $0.summary.uid == uid }) else {
            throw MailClientError.protocolError("no demo message \(uid)")
        }
        return stored
    }
}

nonisolated enum MailClientFactory {
    static func make(demo: Bool) -> any MailClient {
        if demo, let client = DemoMailClient.shared { return client }
        return LiveMailClient()
    }
}
#endif
