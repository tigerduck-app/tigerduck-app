#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailTextRulesTests {
    private static func cfEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    private static func big5(_ text: String) -> Data {
        text.data(using: cfEncoding(.big5))!
    }

    // MARK: A.5 charsets

    @Test func big5IsDecodedAsItsHKSCSSuperset() {
        // 0x88 0x40 exists only in HKSCS; a plain Big5 decoder rejects the whole body.
        let decoded = MailCharset.decode(Self.big5("中文") + Data([0x88, 0x40]), label: "big5")
        #expect(decoded.hasPrefix("中文"))
        #expect(decoded.count == 3)
    }

    @Test(arguments: ["big5", "BIG-5", "cn-big5", "x-x-big5", "\"big5\""])
    func big5Aliases(label: String) {
        #expect(MailCharset.encoding(forLabel: label) == Self.cfEncoding(.big5_HKSCS_1999))
    }

    @Test(arguments: ["gb2312", "GB_2312-80", "gbk", "x-gbk"])
    func gbAliasesUseGB18030(label: String) {
        #expect(MailCharset.encoding(forLabel: label) == Self.cfEncoding(.GB_18030_2000))
    }

    @Test func unknownLabelTriesStrictUTF8First() {
        #expect(MailCharset.decode(Data("中文".utf8), label: "x-unknown") == "中文")
    }

    @Test func unlabelledBig5FallsBackToHKSCS() {
        #expect(MailCharset.decode(Self.big5("課程"), label: nil) == "課程")
    }

    @Test func undecodableBytesFallBackToLatin1WithoutLoss() {
        let bytes: [UInt8] = [0xFF, 0x80, 0xFF]
        #expect(MailCharset.decode(Data(bytes), label: nil).unicodeScalars.map(\.value) == [0xFF, 0x80, 0xFF])
    }

    /// Mail2000 routinely labels a part `us-ascii` and then puts UTF-8 bytes in it. The label
    /// resolves, so decoding it leniently succeeds on every byte and turns 親愛的同學您好 into
    /// `è¦ªæ„›çš„…`. Strict UTF-8 therefore runs before the lenient path: a body that is valid
    /// UTF-8 is UTF-8, whatever the header claims.
    @Test(arguments: ["us-ascii", "US-ASCII", "ascii", "\"us-ascii\""])
    func aBodyMislabelledASCIIButWrittenInUTF8StillReadsAsUTF8(label: String) {
        #expect(MailCharset.decode(Data("親愛的同學您好".utf8), label: label) == "親愛的同學您好")
        #expect(MailCharset.decode(Data("hello 🎓 世界".utf8), label: label) == "hello 🎓 世界")
    }

    /// The other direction, which the UTF-8 fallback above must not cost: a body that really is
    /// in its labelled charset is decoded with that charset, not guessed at.
    @Test func aGenuinelyBig5BodyStillDecodesAsBig5() {
        #expect(MailCharset.decode(Self.big5("親愛的同學您好"), label: "big5") == "親愛的同學您好")
        #expect(MailCharset.decode(Self.big5("課程公告"), label: "Big5") == "課程公告")
    }

    // MARK: RFC 2047

    @Test func decodesUTF8Base64Words() {
        #expect(RFC2047.decode("=?utf-8?B?546L5aSn5piO?=") == "王大明")
    }

    @Test func decodesQEncoding() {
        #expect(RFC2047.decode("=?UTF-8?Q?Caf=C3=A9_menu?=") == "Café menu")
    }

    @Test func decodesBig5WordsWithTheA5Rules() {
        let word = "=?big5?B?\(Self.big5("課程").base64EncodedString())?="
        #expect(RFC2047.decode(word) == "課程")
    }

    @Test func joinsAdjacentEncodedWords() {
        #expect(RFC2047.decode("=?utf-8?B?546L?= =?utf-8?B?5aSn5piO?=") == "王大明")
    }

    @Test func leavesPlainAndMalformedTextAlone() {
        #expect(RFC2047.decode("Hello") == "Hello")
        #expect(RFC2047.decode("=?utf-8?B?***?=") == "=?utf-8?B?***?=")
        #expect(RFC2047.decode("Re: =?utf-8?B?546L?= x") == "Re: 王 x")
    }

    // MARK: Modified UTF-7 (A.1 names)

    @Test(arguments: [
        ("&W8RO9lCZTv1TIw-", "寄件備份匣"),
        ("&g0l6P1Mj-", "草稿匣"),
        ("&Vt5lNntS-", "回收筒"),
        ("&XuNUSk,hUyM-", "廣告信匣"),
        ("Moodle &irJ6C4oOitZTQA-", "Moodle 課程討論區"),
        ("A&-B", "A&B"),
        ("INBOX", "INBOX"),
    ])
    func decodesMailboxNames(raw: String, expected: String) {
        #expect(ModifiedUTF7.decode(raw) == expected)
    }

    // MARK: A.3

    @Test func stripsBidiControls() {
        #expect(MailTextCleaner.clean("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        let all = "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}\u{061C}"
        #expect(MailTextCleaner.clean("a\(all)b") == "ab")
        #expect(MailTextCleaner.clean("課程公告") == "課程公告")
    }

    @Test func stripsControlCharacters() {
        #expect(MailTextCleaner.clean("setup.apk\u{0001}") == "setup.apk")
        #expect(MailTextCleaner.clean("a\u{000B}\u{000C}\u{001F}\u{007F}b") == "ab")
    }

    /// Android's `CONTROLS` leaves `\t`, `\n` and `\r` out of the delete set on purpose, so the
    /// whitespace collapse turns a run of them into a single space. Deleting them instead would
    /// join two words the collapse keeps apart — `verify\naccount` would read as one token and
    /// stop matching the keyword `verify your account` spelled with a line break in it.
    @Test func collapsesTabsAndNewlinesInsteadOfDeletingThem() {
        #expect(MailTextCleaner.clean("verify\tyour\naccount") == "verify your account")
        #expect(MailTextCleaner.clean("a  \r\n\t b") == "a b")
        #expect(MailTextCleaner.clean("  padded  ") == "padded")
        #expect(MailTextCleaner.clean("") == "")
    }

    /// `clean` must leave U+200B alone. Java's `\s` is ASCII-only, but Foundation's
    /// `CharacterSet.whitespaces` contains U+200B on Darwin, so collapsing with it would
    /// rewrite `ntust.e<U+200B>du.tw` as `ntust.e du.tw` — one host broken into two words,
    /// where Android keeps it whole. Removing it is `visibleText`'s job.
    @Test func cleanLeavesZeroWidthSpacesForVisibleTextToRemove() {
        #expect(MailTextCleaner.clean("ntust.e\u{200B}du.tw") == "ntust.e\u{200B}du.tw")
        #expect(MailTextCleaner.visibleText("ntust.e\u{200B}du.tw") == "ntust.edu.tw")
    }

    /// U+200B is spelled out in `visibleText` rather than left to `generalCategory`, which
    /// reports `.format` on this toolchain but answers from the platform's Unicode tables at
    /// run time and has reported otherwise in earlier Unicode versions. This pins the
    /// requirement whichever mechanism ends up satisfying it.
    @Test(arguments: [
        "\u{200B}", "\u{2060}", "\u{00AD}", "\u{FEFF}", "\u{001C}", "\u{0000}", "\u{007F}",
        "\u{0090}", "\u{202E}", "\u{200F}", "\u{061C}", "\u{2069}", "\u{0009}", "\u{000A}",
    ])
    func visibleTextRemovesEveryInvisibleCharacter(invisible: String) {
        #expect(MailTextCleaner.visibleText("a\(invisible)b") == "ab")
    }

    @Test func visibleTextKeepsCharactersTheReaderCanSee() {
        #expect(MailTextCleaner.visibleText("課程 公告 a1.") == "課程 公告 a1.")
    }

    // MARK: A.1 folders

    @Test func mapsMail2000FoldersByTheirIMAPNames() {
        let available = ["INBOX", "&W8RO9lCZTv1TIw-", "&g0l6P1Mj-", "&Vt5lNntS-", "&XuNUSk,hUyM-",
                         "Sent Messages", "Sent", "Moodle &irJ6C4oOitZTQA-"]
        let map = MailFolderMap.resolve(available: available)
        #expect(map[.inbox] == "INBOX")
        #expect(map[.sent] == "&W8RO9lCZTv1TIw-")
        #expect(map[.drafts] == "&g0l6P1Mj-")
        #expect(map[.junk] == "&XuNUSk,hUyM-")
        #expect(map[.trash] == "&Vt5lNntS-")
        #expect(MailFolderMap.otherFolders(available: available) == ["Moodle &irJ6C4oOitZTQA-", "Sent", "Sent Messages"])
    }

    @Test func fallsBackToDecodedNamesAndNeverInventsFolders() {
        let map = MailFolderMap.resolve(available: ["INBOX", "寄件備份匣"])
        #expect(map[.sent] == "寄件備份匣")
        #expect(map[.trash] == nil)
    }

    // MARK: Addresses and raw headers

    @Test func parsesAddressLists() {
        let parsed = MailAddress.parseList("\"Wang, Da-Ming\" <dm@mail.ntust.edu.tw>; b@x.org ,  王 <c@y.tw>")
        #expect(parsed == [
            MailAddress(name: "Wang, Da-Ming", address: "dm@mail.ntust.edu.tw"),
            MailAddress(name: nil, address: "b@x.org"),
            MailAddress(name: "王", address: "c@y.tw"),
        ])
        #expect(parsed.allSatisfy { $0.isPlausible })
        #expect(!MailAddress(name: nil, address: "not an address").isPlausible)
    }

    /// A token whose address portion carries a smuggled CR/LF (header-injection bait) or
    /// any other whitespace/control character must never become a `MailAddress` — it's
    /// dropped, not merely flagged, matching the plain `local@domain` shape
    /// `AddressParser.looksLikeAddress` requires on Android.
    @Test func rejectsAddressesCarryingControlCharacters() {
        #expect(MailAddress.parseList("a@x.tw\r\nBcc: b@y.tw") == [])
        #expect(MailAddress.parseList("ok@x.tw, a@x.tw\r\nBcc: b@y.tw, also@x.tw") == [
            MailAddress(name: nil, address: "ok@x.tw"),
            MailAddress(name: nil, address: "also@x.tw"),
        ])
        #expect(!MailAddress(name: nil, address: "a@x.tw\r\nBcc: b@y.tw").isPlausible)
    }

    @Test func findsFoldedHeadersInRawSource() {
        let raw = Data("From: a@b.c\r\nReply-To: \"Office\"\r\n <office@mail.ntust.edu.tw>\r\nSubject: x\r\n\r\nReply-To: body@not.header\r\n".utf8)
        #expect(MailRawHeaders.value(named: "reply-to", in: raw) == "\"Office\" <office@mail.ntust.edu.tw>")
        #expect(MailRawHeaders.value(named: "Cc", in: raw) == nil)
    }
    /// Android's `String(bytes, charset)` substitutes U+FFFD and always returns; iOS's
    /// `String(data:encoding:)` returns nil, so one truncated byte in a correctly labelled UTF-8
    /// body used to fall through to the guess chain — where Big5-HKSCS accepts almost anything
    /// and the whole message rendered as mojibake.
    @Test func aLabelledBodyWithOneBadByteStillDecodesAsThatCharset() {
        var bytes = Array("這是中文測試".utf8)
        bytes.insert(0xE4, at: 6) // a stray UTF-8 lead byte between 是 and 中
        let text = MailCharset.decode(Data(bytes), label: "utf-8")
        #expect(text.contains("這是"))
        #expect(text.contains("中文測試"))
        #expect(text.contains("\u{FFFD}"))
    }

    @Test func anUnlabelledBodyStillUsesTheGuessChain() {
        let big5 = MailCharset.encoding(forLabel: "big5")
        let data = "中文".data(using: big5 ?? .utf8) ?? Data()
        #expect(MailCharset.decode(data, label: nil) == "中文")
    }
}
#endif
