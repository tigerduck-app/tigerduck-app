#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailComposeRulesTests {
    static let me = MailAddress(name: "王大明", address: "b10000000@mail.ntust.edu.tw")
    static let date = ISO8601DateFormatter().date(from: "2026-09-16T00:00:00+08:00")!

    static func mail(
        to: [MailAddress] = [MailAddress(name: nil, address: "office@mail.ntust.edu.tw")],
        bcc: [MailAddress] = [],
        subject: String = "選課問題",
        body: String = "老師好",
        attachments: [OutgoingAttachment] = []
    ) -> OutgoingMail {
        OutgoingMail(from: me, to: to, cc: [], bcc: bcc, subject: subject, body: body,
                     inReplyTo: nil, references: [], attachments: attachments)
    }

    static func text(_ mail: OutgoingMail) -> String {
        String(decoding: MailMessageBuilder.build(mail, messageID: "<id@mail.ntust.edu.tw>", date: date, boundary: "B"), as: UTF8.self)
    }

    @Test func encodesNonASCIINamesAndSubjects() {
        let text = Self.text(Self.mail())
        #expect(text.contains("From: =?UTF-8?B?546L5aSn5piO?= <b10000000@mail.ntust.edu.tw>\r\n"))
        #expect(text.contains("Subject: =?UTF-8?B?\(Data("選課問題".utf8).base64EncodedString())?=\r\n"))
        #expect(text.contains("Date: Wed, 16 Sep 2026 00:00:00 +0800\r\n"))
        #expect(text.contains("Message-ID: <id@mail.ntust.edu.tw>\r\n"))
        #expect(text.contains("MIME-Version: 1.0\r\n"))
    }

    @Test func quotesASCIINames() {
        var mail = Self.mail()
        mail.from = MailAddress(name: "Da-Ming \"DM\" Wang", address: "b10000000@mail.ntust.edu.tw")
        #expect(Self.text(mail).contains("From: \"Da-Ming \\\"DM\\\" Wang\" <b10000000@mail.ntust.edu.tw>\r\n"))
    }

    @Test func splitsLongSubjectsIntoShortEncodedWords() {
        let text = Self.text(Self.mail(subject: String(repeating: "課程公告", count: 20)))
        let subjectLines = text.components(separatedBy: "\r\n").drop { !$0.hasPrefix("Subject:") }
            .prefix { $0.hasPrefix("Subject:") || $0.hasPrefix(" ") }
        #expect(subjectLines.count > 1)
        for line in subjectLines {
            let word = line.replacingOccurrences(of: "Subject: ", with: "").trimmingCharacters(in: .whitespaces)
            #expect(word.count <= 75)
        }
    }

    @Test func keepsBccOutOfTheHeaders() {
        let mail = Self.mail(bcc: [MailAddress(name: nil, address: "secret@mail.ntust.edu.tw")])
        #expect(!Self.text(mail).contains("secret@"))
        #expect(mail.envelopeRecipients == ["office@mail.ntust.edu.tw", "secret@mail.ntust.edu.tw"])
    }

    @Test func deduplicatesEnvelopeRecipientsCaseInsensitively() {
        let mail = Self.mail(to: [MailAddress(name: nil, address: "A@x.tw")], bcc: [MailAddress(name: nil, address: "a@x.tw")])
        #expect(mail.envelopeRecipients == ["A@x.tw"])
    }

    @Test func writesThreadingHeaders() {
        var mail = Self.mail()
        mail.inReplyTo = "<m1@x>"
        mail.references = ["<m0@x>", "<m1@x>"]
        let text = Self.text(mail)
        #expect(text.contains("In-Reply-To: <m1@x>\r\n"))
        #expect(text.contains("References: <m0@x> <m1@x>\r\n"))
    }

    /// A CR/LF (or any other control character) smuggled into a threading header must
    /// never grow an extra header line — stripping them defangs a header-injection
    /// attempt smuggled in through a hostile In-Reply-To or References value. Bcc must
    /// never appear as a header anywhere, only in `envelopeRecipients`.
    @Test func stripsControlCharactersFromThreadingHeaders() {
        var mail = Self.mail()
        mail.inReplyTo = "<m1@x>\r\nBcc: attacker@evil.com\u{07}"
        mail.references = ["<r0@x>\r\nBcc: attacker2@evil.com"]
        let text = Self.text(mail)
        #expect(!text.contains("\r\nBcc:"))
        #expect(!text.contains("\u{07}"))
        #expect(!text.contains("\r\n\r\nBcc"))
    }

    @Test func bodyIsQuotedPrintableWithShortLines() {
        let text = Self.text(Self.mail(body: "中文 \n" + String(repeating: "a", count: 100)))
        #expect(text.contains("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n"))
        #expect(text.contains("=E4=B8=AD=E6=96=87=20\r\n"))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
    }

    @Test func attachmentsUseRFC2231Names() {
        let attachment = OutgoingAttachment(filename: "課程.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 200))
        let text = Self.text(Self.mail(attachments: [attachment, OutgoingAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("x".utf8))]))
        #expect(text.contains("Content-Type: multipart/mixed; boundary=\"B\"\r\n"))
        #expect(text.contains("Content-Disposition: attachment; filename*=UTF-8''%E8%AA%B2%E7%A8%8B.pdf\r\n"))
        #expect(text.contains("Content-Disposition: attachment; filename=\"a.txt\"\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
    }

    /// A hostile `mimeType` (whitespace, a control character, or anything else that
    /// isn't a plain `type/subtype` token) must never be written into the `Content-Type`
    /// header verbatim; it falls back to a safe default instead.
    @Test func fallsBackToASafeMimeTypeWhenMalformed() {
        let attachment = OutgoingAttachment(
            filename: "a.bin", mimeType: "text/plain\r\nBcc: attacker@evil.com", data: Data("x".utf8)
        )
        let text = Self.text(Self.mail(attachments: [attachment]))
        #expect(text.contains("Content-Type: application/octet-stream; name=\"a.bin\"\r\n"))
        #expect(!text.contains("\r\nBcc:"))
    }

    /// A hostile address carrying a smuggled CRLF must never grow an extra header line,
    /// whether it appears in From, To or Cc — `MailAddress.parseList`/`isPlausible`
    /// already reject such a value before it gets this far (see `MailTextRulesTests`),
    /// but `header(for:)` sanitizes as defense in depth for a `MailAddress` built any
    /// other way (a cache, a demo fixture, ...).
    @Test func headerInjectionThroughAddressesIsBlocked() {
        let hostile = MailAddress(name: nil, address: "victim@x.tw\r\nBcc: attacker@evil.com")
        var mail = Self.mail(to: [hostile])
        mail.cc = [hostile]
        mail.from = hostile
        let text = Self.text(mail)
        #expect(!text.contains("\r\nBcc:"))
        #expect(!text.contains("\r\n\r\nBcc"))
    }

    /// `messageID` is a public parameter of `build`; a hostile caller-supplied value must
    /// be sanitized exactly like the other headers.
    @Test func sanitizesTheMessageIDParameter() {
        let hostileID = "<id@mail.ntust.edu.tw>\r\nBcc: attacker@evil.com"
        let data = MailMessageBuilder.build(Self.mail(), messageID: hostileID, date: Self.date, boundary: "B")
        let built = String(decoding: data, as: UTF8.self)
        #expect(!built.contains("\r\nBcc:"))
    }

    @Test func outputIsSevenBit() {
        let data = MailMessageBuilder.build(Self.mail(), messageID: MailMessageBuilder.makeMessageID(), date: Self.date)
        #expect(data.allSatisfy { $0 < 0x80 })
        #expect(MailMessageBuilder.makeMessageID().range(of: #"^<[0-9a-f-]{36}@mail\.ntust\.edu\.tw>$"#, options: .regularExpression) != nil)
    }

    // MARK: Size estimate

    /// The naive `characters * 3` estimate undercounts CJK bodies by roughly 3x (each
    /// UTF-8 byte of a CJK character, itself already ~3 bytes/char, triples again under
    /// quoted-printable). The estimate must stay a true upper bound on the real encoding.
    @Test func encodedSizeEstimateBoundsARealCJKBody() {
        assertEstimateCoversRealMessage(String(repeating: "測試郵件內容", count: 8_000))
    }

    @Test func encodedSizeEstimateBoundsARealASCIIBody() {
        assertEstimateCoversRealMessage(String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: 2_000))
    }

    /// A single unbroken line forces the encoder to soft-wrap every ~75 columns with no
    /// newline resets in between; the estimate's wrap threshold must match the encoder's
    /// exactly; a one-column gap (76 vs. 75) undercounts one soft break per ~75 characters,
    /// which for a run this long is hundreds of missed `=CRLF` triples.
    @Test func encodedSizeEstimateBoundsALongUnbrokenASCIIRun() {
        assertEstimateCoversRealMessage(String(repeating: "a", count: 100_000))
    }

    private func assertEstimateCoversRealMessage(_ body: String) {
        let built = MailMessageBuilder.build(Self.mail(body: body), messageID: "<id@mail.ntust.edu.tw>", date: Self.date, boundary: "B")
        let estimate = MailMessageBuilder.estimateEncodedSize(body: body)
        #expect(estimate >= built.count, "estimate \(estimate) must be >= actual \(built.count)")
    }

    // MARK: Reply composition

    @Test func subjectsGetOnePrefix() {
        #expect(MailReplyComposer.replySubject("選課") == "Re: 選課")
        #expect(MailReplyComposer.replySubject("RE: 選課") == "RE: 選課")
        #expect(MailReplyComposer.forwardSubject("x") == "Fwd: x")
        #expect(MailReplyComposer.forwardSubject("Fw: x") == "Fw: x")
    }

    @Test func quotesTheOriginalBody() {
        let original = MailOriginal(from: MailAddress(name: "教務處", address: "a@mail.ntust.edu.tw"), to: [], cc: [],
                                    subject: "s", date: nil, messageID: nil, references: [], bodyText: "a\r\nb")
        #expect(MailReplyComposer.quotedBody(of: original, dateText: "2026/09/16").hasSuffix("\n> a\n> b"))
    }

    /// The forward header block's exact wording comes from `app-translation` (Task 18) and
    /// isn't available yet at this point in the plan, so — like `quotesTheOriginalBody`
    /// above — this only checks the structure: two blank lines, a 5-line header block
    /// (forwarded-message marker, From, Date, Subject, To — design doc §6.4, matches
    /// Android's `ComposePrefill.forward`), a blank line, then the original text unquoted.
    @Test func forwardsWithAStructuredHeaderBlock() {
        let original = MailOriginal(
            from: MailAddress(name: "教務處", address: "a@mail.ntust.edu.tw"),
            to: [MailAddress(name: nil, address: "b@x.tw")], cc: [],
            subject: "s", date: nil, messageID: nil, references: [], bodyText: "a\r\nb"
        )
        let forwarded = MailReplyComposer.forwardBody(of: original, dateText: "2026/09/16")
        let parts = forwarded.components(separatedBy: "\n\n")
        #expect(parts.count == 3)
        #expect(parts[0].isEmpty)
        #expect(parts[1].components(separatedBy: "\n").count == 5)
        #expect(parts[2] == "a\nb")
    }

    @Test func formatsAddressesForTheForwardHeader() {
        #expect(MailReplyComposer.formatted(MailAddress(name: "教務處", address: "a@mail.ntust.edu.tw")) == "教務處 <a@mail.ntust.edu.tw>")
        #expect(MailReplyComposer.formatted(MailAddress(name: nil, address: "b@x.tw")) == "b@x.tw")
        #expect(MailReplyComposer.formatted(nil as MailAddress?) == "")
        #expect(MailReplyComposer.formatted([MailAddress(name: nil, address: "b@x.tw"), MailAddress(name: "D", address: "d@x.tw")]) == "b@x.tw, D <d@x.tw>")
    }

    /// A display name containing an RFC 5322 special (here a comma, and a literal quote)
    /// must be quoted and escaped so the formatted string round-trips through
    /// `MailAddress.parseList` — matching Android's `ComposeRules.formatOne` and its
    /// `formatRecipients output round-trips through parseRecipients` test.
    @Test func formattedRecipientsRoundTripThroughAddressParsing() {
        let addresses = [
            MailAddress(name: "B, C", address: "b@y.tw"),
            MailAddress(name: "a \"quoted\" name", address: "q@y.tw"),
            MailAddress(name: "王小明", address: "wang@y.tw"),
            MailAddress(name: nil, address: "bare@y.tw"),
        ]
        #expect(MailAddress.parseList(MailReplyComposer.formatted(addresses)) == addresses)
    }

    @Test func replyGoesToReplyToAndReplyAllCopiesTheRest() {
        let from = MailAddress(name: nil, address: "teacher@mail.ntust.edu.tw")
        let replyTo = [MailAddress(name: nil, address: "office@mail.ntust.edu.tw")]
        let original = MailOriginal(
            from: from,
            to: [MailAddress(name: nil, address: "B10000000@mail.ntust.edu.tw"), MailAddress(name: nil, address: "b@x.tw")],
            cc: [MailAddress(name: nil, address: "c@x.tw"), MailAddress(name: nil, address: "B@X.tw")],
            subject: "s", date: nil, messageID: nil, references: [], bodyText: ""
        )
        let reply = MailReplyComposer.replyRecipients(to: original, replyTo: replyTo, me: Self.me.address, replyAll: false)
        #expect(reply.to == replyTo)
        #expect(reply.cc.isEmpty)
        let all = MailReplyComposer.replyRecipients(to: original, replyTo: replyTo, me: Self.me.address, replyAll: true)
        #expect(all.to == replyTo)
        #expect(all.cc.map(\.address) == ["b@x.tw", "c@x.tw"])
        let noReplyTo = MailReplyComposer.replyRecipients(to: original, replyTo: [], me: Self.me.address, replyAll: false)
        #expect(noReplyTo.to == [from])
    }

    /// A Mail2000 bounce's sender survives as a display name with no address
    /// (`MailAddress.parseSender`). Reply, reply-all and forward must all refuse to address
    /// anything to it: never a `MAILER-DAEMON` recipient, never a `Mail Deliver System <>`
    /// token in the To field. The reply simply opens with no recipient — which compose
    /// then blocks on — while the forward's header block still prints the name.
    @Test func aSenderWithNoAddressNeverBecomesARecipient() {
        let daemon = MailAddress(name: "Mail Deliver System", address: "")
        let original = MailOriginal(
            from: daemon,
            to: [MailAddress(name: nil, address: "B10000000@mail.ntust.edu.tw"), daemon],
            cc: [daemon],
            subject: "Returned Mail", date: nil, messageID: nil, references: [], bodyText: "x"
        )
        let reply = MailReplyComposer.replyRecipients(to: original, replyTo: [], me: Self.me.address, replyAll: false)
        #expect(reply.to.isEmpty)
        #expect(reply.cc.isEmpty)
        let all = MailReplyComposer.replyRecipients(to: original, replyTo: [], me: Self.me.address, replyAll: true)
        #expect(all.to.isEmpty)
        #expect(all.cc.isEmpty)

        // Nothing addressable anywhere in either result, and no empty `<>` token either.
        #expect(MailReplyComposer.formatted(all.to + all.cc).isEmpty)
        #expect(MailReplyComposer.formatted(daemon) == "Mail Deliver System")
        #expect(!MailReplyComposer.forwardBody(of: original, dateText: "2026/09/18").contains("<>"))
        #expect(MailReplyComposer.forwardBody(of: original, dateText: "2026/09/18").contains("Mail Deliver System"))
    }

    @Test func threadingHeadersExtendReferences() {
        let original = MailOriginal(from: nil, to: [], cc: [], subject: "", date: nil,
                                    messageID: "<m1@x>", references: ["<m0@x>"], bodyText: "")
        let headers = MailReplyComposer.threadingHeaders(for: original)
        #expect(headers.inReplyTo == "<m1@x>")
        #expect(headers.references == ["<m0@x>", "<m1@x>"])
    }
    /// `In-Reply-To`/`References` are the only header values this builder echoes back from a
    /// *received* mail, and a received `Message-ID` is attacker-controlled free text. RFC 5322
    /// `msg-id`s are ASCII and Mail2000 announces no SMTPUTF8, so a non-ASCII token is the one
    /// remaining way raw 8-bit bytes could reach the wire — it is dropped whole rather than
    /// mangled into something that identifies no message anywhere.
    @Test func nonASCIIThreadingReferencesAreDroppedRatherThanSentAsRawUTF8() {
        var mail = Self.mail()
        mail.inReplyTo = "<王大明@evil.example>"
        mail.references = ["<real@mail.ntust.edu.tw>", "<王大明@evil.example>"]
        let built = MailMessageBuilder.build(mail, messageID: "<id@mail.ntust.edu.tw>", date: Self.date, boundary: "B")
        let text = String(decoding: built, as: UTF8.self)

        #expect(!text.contains("In-Reply-To:"))
        #expect(text.contains("References: <real@mail.ntust.edu.tw>\r\n"))
        #expect(!text.contains("王大明@evil.example"))
    }

    /// The whole header block stays 7-bit even when every echoed value is hostile: the body is
    /// quoted-printable, the subject and display name are RFC 2047 encoded words, and the
    /// addresses are ASCII-validated before they get here.
    @Test func theBuiltMessageIsSevenBitEvenWithNonASCIIThreadingAndNames() {
        var mail = Self.mail(subject: "選課問題", body: "老師好，附件是選課單")
        mail.inReplyTo = "<訊息@evil.example>"
        mail.references = ["<訊息@evil.example>"]
        let built = MailMessageBuilder.build(mail, messageID: "<id@mail.ntust.edu.tw>", date: Self.date, boundary: "B")
        #expect(built.allSatisfy { $0 < 0x80 })
    }

    /// An ordinary ASCII thread is untouched — the rule above must not cost normal threading.
    @Test func asciiThreadingHeadersAreKept() {
        var mail = Self.mail()
        mail.inReplyTo = "<a@mail.ntust.edu.tw>"
        mail.references = ["<a@mail.ntust.edu.tw>", "<b@mail.ntust.edu.tw>"]
        let text = Self.text(mail)
        #expect(text.contains("In-Reply-To: <a@mail.ntust.edu.tw>\r\n"))
        #expect(text.contains("References: <a@mail.ntust.edu.tw> <b@mail.ntust.edu.tw>\r\n"))
    }
}
#endif
