#if os(iOS)
import Foundation
import SwiftMail
import Testing
@testable import TigerDuck

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
        #expect(attachment.filename == "report.pdf")
        let bytes = try #require(attachment.decodedData())
        #expect(String(decoding: bytes, as: UTF8.self) == "%PDF-1.4\n")
    }

    @Test func decodesBig5HeaderAndBody() throws {
        let data = try SchoolMailFixtures.rawEML("big5-plain")
        let message = try EMLParser.parse(data)
        #expect(MailRawHeaders.value(named: "subject", in: data) == "中文")
        let part = try #require(message.parts.first)
        let body = try #require(part.decodedData())
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

    @Test func readsTheNullReversePathOfAMail2000Bounce() throws {
        let data = try SchoolMailFixtures.rawEML("bounce-no-domain")
        let returnPath = MailRawHeaders.value(named: "return-path", in: data)
        #expect(returnPath == "<>")
        #expect(MailWarnings.isBounce(returnPath: returnPath))
    }

    @Test func theDetailFetchReadsTheServersReturnPathAndNotALaterOne() {
        let info = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            additionalHeaderFields: [
                HeaderField(name: "Return-Path", value: "<>"),
                HeaderField(name: "Received", value: "by mail.ntust.edu.tw"),
                HeaderField(name: "Return-Path", value: "<attacker@evil.example>"),
            ]
        )
        #expect(LiveMailClient.returnPath(from: info) == "<>")
        #expect(LiveMailClient.returnPath(from: MessageInfo(sequenceNumber: SequenceNumber(1))) == nil)
    }

    @Test func theDetailFetchReadsReplyToFromTheHeaderSection() {
        let info = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            additionalHeaderFields: [HeaderField(name: "Reply-To", value: "=?UTF-8?B?5pWZ5YuZ6JmV?= <office@mail.ntust.edu.tw>")]
        )
        #expect(LiveMailClient.replyTo(from: info) == "教務處 <office@mail.ntust.edu.tw>")
        let without = MessageInfo(sequenceNumber: SequenceNumber(1), additionalHeaderFields: [HeaderField(name: "Received", value: "x")])
        #expect(LiveMailClient.replyTo(from: without) == "")
        #expect(LiveMailClient.replyTo(from: MessageInfo(sequenceNumber: SequenceNumber(1))) == nil)
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
