#if os(iOS)
import Foundation
import SwiftMail
import Testing
@testable import TigerDuck

/// Feeds the shared `.eml` corpus (design doc §12.4; also Android's
/// `AngusMailSessionReadTest`) through SwiftMail's offline `EMLParser`, so nested
/// multipart, Big5 and RFC 2231 parsing get real coverage without a socket.
struct LiveMailClientParsingTests {
    @Test func decodesNestedMultipartAlternative() throws {
        let data = try SchoolMailFixtures.rawEML("multipart-alternative")
        let message = try EMLParser.parse(data)
        #expect(MailRawHeaders.value(named: "subject", in: data) == "中文信件")
        #expect(message.parts.map(\.contentType) == ["text/plain; charset=UTF-8", "text/html; charset=UTF-8"])
        #expect(message.textBody?.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello 中文")
        #expect(message.htmlBody?.contains("<b>html</b>") == true)
    }

    @Test func decodesTheRFC2231AttachmentName() throws {
        let data = try SchoolMailFixtures.rawEML("with-attachment")
        let message = try EMLParser.parse(data)
        #expect(message.textBody?.trimmingCharacters(in: .whitespacesAndNewlines) == "See attached.")
        #expect(message.attachments.count == 1)
        let attachment = try #require(message.attachments.first)
        #expect(attachment.contentType == "application/pdf")
        // See Step 7: EMLParser prefers Content-Type's plain `name=` here; the live IMAP
        // path (used by LiveMailClient) prefers Content-Disposition's `filename*=` and
        // would read "報告.pdf" instead — checked manually in Task 19.
        #expect(attachment.filename == "report.pdf")
        let bytes = try #require(attachment.decodedData())
        #expect(String(decoding: bytes, as: UTF8.self) == "%PDF-1.4\n")
    }

    @Test func decodesBig5HeaderAndBody() throws {
        let data = try SchoolMailFixtures.rawEML("big5-plain")
        let message = try EMLParser.parse(data)
        // The app's A.5 rules, not EMLParser's own (Big5-blind) RFC 2047 decoder.
        #expect(MailRawHeaders.value(named: "subject", in: data) == "中文")
        let part = try #require(message.parts.first)
        let body = try #require(part.decodedData())
        // The fixture's QP-encoded line has no soft line break, so the file's trailing
        // newline decodes as a literal byte — trimmed here as every other body assertion
        // in this file already does.
        #expect(
            MailCharset.decode(body, label: part.declaredCharset)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "中文郵件"
        )
    }

    @Test func decodesTheRelatedInlineImage() throws {
        let data = try SchoolMailFixtures.rawEML("related-inline")
        let message = try EMLParser.parse(data)
        #expect(message.attachments.isEmpty)
        let inline = try #require(message.cids.first { $0.contentId == "logo@x" })
        #expect(inline.contentType == "image/png")
        #expect(inline.decodedData() == Data(base64Encoded: "iVBORw0KGgo="))
    }

    /// A reduced Mail2000 delivery-failure notice (the real one the author received, with
    /// the student's own address replaced by this corpus's `b10000001` and the returned
    /// message stripped out). Its `From` is a display name over a bare local part with no
    /// `@domain`, which the strict list parser drops whole — name and all — leaving the row
    /// reading 「（沒有寄件者）」. `parseSender` keeps the name and no address.
    @Test func keepsTheSenderNameOfAMail2000Bounce() throws {
        let data = try SchoolMailFixtures.rawEML("bounce-no-domain")
        let from = try #require(MailRawHeaders.value(named: "from", in: data))
        #expect(from == "\"Mail Deliver System\" <MAILER-DAEMON>")
        #expect(MailAddress.parseList(from).isEmpty)

        let sender = try #require(MailAddress.parseSender(from))
        #expect(sender.name == "Mail Deliver System")
        #expect(sender.address.isEmpty)
        #expect(!sender.isPlausible)
        #expect(sender.displayName == "Mail Deliver System")
    }

    @Test func decodesTheMail2000Shape() throws {
        let data = try SchoolMailFixtures.rawEML("mail2000-sample")
        let message = try EMLParser.parse(data)
        #expect(MailRawHeaders.value(named: "from", in: data) == "\"中文\" <b10000001@mail.ntust.edu.tw>")
        #expect(MailRawHeaders.value(named: "reply-to", in: data) == "\"中文\" <b10000001@mail.ntust.edu.tw>")
        #expect(message.textBody?.trimmingCharacters(in: .whitespacesAndNewlines) == "Test email to myself")
    }
}
#endif
