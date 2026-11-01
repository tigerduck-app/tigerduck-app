#if os(iOS)
import Foundation

/// The demo mailbox: `demo.json`'s `mail` section, its messages numbered by date in each folder.
nonisolated struct MailDemoFixture: Sendable {
    /// The file keeps an attachment's name and size, not its contents.
    struct Attachment: Sendable {
        var filename: String
        var contentType: String
        var size: Int
    }

    struct Entry: Sendable {
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

    static func load(from bundle: Bundle, in language: DemoLanguage = .shown) -> MailDemoFixture? {
        guard let url = bundle.url(forResource: "demo", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return MailDemoFixture(file.mail, in: language)
    }

    func matches(studentID: String, password: String) -> Bool {
        studentID.caseInsensitiveCompare(studentId) == .orderedSame && password == self.password
    }
}

extension MailDemoFixture {
    private init(_ mailbox: Mailbox, in language: DemoLanguage) {
        var folders = Dictionary(uniqueKeysWithValues: MailFolderRole.allCases.map { ($0.imapName, [Entry]()) })
        let dated = mailbox.messages.compactMap { message in DemoTime.date(message.date).map { (message, $0) } }
        for (message, date) in dated.sorted(by: { $0.1 < $1.1 }) {
            let folder = (message.folder.flatMap(MailFolderRole.init(rawValue:)) ?? .inbox).imapName
            let uid = UInt32(folders[folder, default: []].count + 1)
            folders[folder, default: []].append(message.entry(uid: uid, date: date, in: language))
        }
        self.init(studentId: mailbox.studentId, password: mailbox.password, uidValidity: 1, folders: folders)
    }

    private struct File: Decodable {
        let mail: Mailbox
    }

    private struct Mailbox: Decodable {
        let studentId: String
        let password: String
        let messages: [Message]
    }

    private struct Address: Decodable {
        let name: DemoText?
        let address: String
    }

    private struct Message: Decodable {
        struct Attachment: Decodable {
            let name: DemoText
            let type: String?
            let size: Int?
        }

        let from: Address
        let to: [Address]?
        let subject: DemoText
        let date: String
        let seen: Bool?
        let folder: String?
        let html: DemoText?
        let plain: DemoText?
        let attachments: [Attachment]?

        func entry(uid: UInt32, date: Date, in language: DemoLanguage) -> Entry {
            let html = self.html?.text(in: language)
            let name = from.name?.text(in: language)
            return Entry(
                uid: uid, fromName: name?.isEmpty == false ? name : nil, fromAddress: from.address,
                to: (to ?? []).map(\.address), subject: subject.text(in: language), date: date, seen: seen ?? false,
                text: plain?.text(in: language) ?? html.map(MailHTMLSanitizer.plainText(fromHTML:)) ?? "", html: html,
                attachments: (attachments ?? []).map {
                    MailDemoFixture.Attachment(
                        filename: $0.name.text(in: language), contentType: $0.type ?? "application/octet-stream",
                        size: $0.size ?? 0
                    )
                }
            )
        }
    }
}
#endif
