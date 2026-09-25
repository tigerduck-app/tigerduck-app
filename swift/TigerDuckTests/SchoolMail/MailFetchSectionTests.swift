#if os(iOS)
import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import SwiftMail
import Testing
@testable import TigerDuck

/// Why the message screen may never ask for a *named* header-field list, and why a response it
/// cannot decode must not be reported as an unreachable server.
///
/// On a real device every message open failed with "Can't reach the mail server" while the list
/// loaded fine. The list fetch asks for envelope/flags/size/bodystructure; the detail fetch was
/// the one call site that also passed `headerFields: ["References"]`, which SwiftMail encodes as
/// `BODY.PEEK[HEADER.FIELDS ("References")]` — the field name quoted, as RFC 3501 allows.
/// Mail2000 echoes that section back uppercased *and* quoted a second time, and the response
/// stops being IMAP.
///
/// Nothing below is a stand-in. The responses are fed through `IMAPClientHandler`, the same NIO
/// handler SwiftMail installs on its own channel, so a failing case produces the real
/// `IMAPDecoderError` SwiftMail hands to `LiveMailClient.map(_:)`.
struct MailFetchSectionTests {

    // MARK: Server responses

    /// One untagged FETCH carrying `section` as a literal. `section` is written exactly as the
    /// server sends it, so a test can reproduce a server's own mangling of it.
    static func fetchResponse(section: String, literal: String) -> String {
        "* 1 FETCH (UID 4242 BODY[\(section)] {\(literal.utf8.count)}\r\n\(literal))\r\n"
    }

    static let headerBlock = "From: a@mail.ntust.edu.tw\r\nReferences: <first@ntust> <second@ntust>\r\n\r\n"

    /// What Mail2000 actually sent. The first 32 bytes of this, on the wire, are
    /// `20424f44595b4845414445522e4649454c4453202822225245464552454e4345` — the same bytes the
    /// device's SwiftMail log reported inside the failing `FetchMessageInfoCommand<UID>`.
    static let mail2000Echo = fetchResponse(section: #"HEADER.FIELDS (""REFERENCES"")"#, literal: headerBlock)

    /// The same section echoed the way RFC 3501 says it should be — proving the request TigerDuck
    /// *sent* was well-formed and it is the server's re-quoting that breaks the response.
    static let conformingEcho = fetchResponse(section: #"HEADER.FIELDS ("References")"#, literal: headerBlock)

    /// `BODY.PEEK[HEADER]`'s echo, uppercased the way Mail2000 uppercases. There is no
    /// parenthesised list in it, so there is nothing for a server to re-quote.
    static let fullHeaderEcho = fetchResponse(section: "HEADER", literal: headerBlock)

    // MARK: Decoding through NIOIMAP's real client pipeline

    static func decode(_ response: String) -> Result<[Response], any Error> {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        do {
            try channel.pipeline.syncOperations.addHandler(IMAPClientHandler())
            try channel.writeInbound(ByteBuffer(string: response))
        } catch {
            return .failure(error)
        }
        var decoded: [Response] = []
        while let next = ((try? channel.readInbound(as: Response.self)) ?? nil) {
            decoded.append(next)
        }
        return .success(decoded)
    }

    static func decodeFailure(_ response: String) throws -> any Error {
        guard case .failure(let error) = decode(response) else {
            Issue.record("expected \(response) to fail decoding")
            throw MailClientError.protocolError("expected a decode failure")
        }
        return error
    }

    // MARK: The parse failure

    @Test func mail2000sRequotedHeaderFieldListCannotBeDecoded() throws {
        let error = try Self.decodeFailure(Self.mail2000Echo)
        let described = String(describing: error)
        // The exact error the device logged: NIOIMAP reads the leading `""` as an empty quoted
        // string, then meets a bare `REFERENCES` where the closing `)` belongs.
        #expect(described.contains("IMAPDecoderError"))
        #expect(described.contains("none of the options match"))
    }

    @Test func aConformingEchoOfTheSameSectionDecodesFine() {
        guard case .success(let responses) = Self.decode(Self.conformingEcho) else {
            Issue.record("the RFC-conforming echo must decode")
            return
        }
        #expect(!responses.isEmpty)
    }

    @Test func theFullHeaderSectionDecodesEvenUppercased() {
        guard case .success(let responses) = Self.decode(Self.fullHeaderEcho) else {
            Issue.record("BODY[HEADER] has no list to mangle and must decode")
            return
        }
        #expect(!responses.isEmpty)
    }

    @Test func theFullHeaderSectionStillCarriesReferences() throws {
        // What `BODY.PEEK[HEADER]` delivers is a `.body` section of kind `.header` whose bytes
        // are the message's whole header block — which is what SwiftMail's
        // `FetchMessageInfoHandler` collects (it gates on exactly `.header`/`.headerFields`) and
        // parses `References:` out of into `MessageInfo.references`. Threading survives the
        // switch away from the named field list.
        guard case .success(let responses) = Self.decode(Self.fullHeaderEcho) else {
            Issue.record("BODY[HEADER] must decode")
            return
        }
        var sawHeaderSection = false
        var streamed = ""
        for response in responses {
            guard case .fetch(let fetch) = response else { continue }
            switch fetch {
            case .streamingBegin(let kind, _):
                if case .header = kind.sectionSpecifier.kind { sawHeaderSection = true }
            case .streamingBytes(let bytes):
                streamed += String(decoding: bytes.readableBytesView, as: UTF8.self)
            default:
                break
            }
        }
        #expect(sawHeaderSection)
        #expect(streamed.contains("References: <first@ntust> <second@ntust>"))
    }

    // MARK: How the failure is reported to the user

    @Test func aDecodeFailureIsAProtocolErrorNotAnUnreachableServer() throws {
        // The whole misdiagnosis: `map(_:)` used to end in `classify(..., fallback: .unreachable)`,
        // an `IMAPDecoderError` matches none of the known shapes, so a parser failure became
        // `.unreachable` → `LoginError.network` → "Can't reach the mail server" on a device
        // whose network was fine. A response this client cannot read is a protocol failure.
        let error = try Self.decodeFailure(Self.mail2000Echo)
        #expect(LiveMailClient.map(error) == .protocolError(String(describing: error)))
    }

    @Test func genuinelyNetworkShapedErrorsStayUnreachable() {
        #expect(LiveMailClient.map(IMAPError.timeout) == .unreachable)
        #expect(LiveMailClient.map(IMAPError.connectionFailed("connection reset by peer")) == .unreachable)
        #expect(LiveMailClient.map(URLError(.notConnectedToInternet)) == .unreachable)
        #expect(LiveMailClient.map(URLError(.timedOut)) == .unreachable)
    }

    // MARK: What the detail fetch now asks for

    @Test func theDetailFetchSendsNoQuotedHeaderFieldList() {
        let command = FetchMessageInfoRequest.wireCommand(
            options: LiveMailClient.detailOptions,
            headerFields: LiveMailClient.detailHeaderFields
        )
        #expect(command.contains("BODY.PEEK[HEADER]"))
        // No parenthesised list of field names, so nothing for the server to re-quote — and no
        // quoted string anywhere in the command for it to double up.
        #expect(!command.contains("HEADER.FIELDS"))
        #expect(!command.contains("\""))
    }

    @Test func theDetailFetchStillAsksForTheHeaderSectionThatCarriesReferences() {
        // ENVELOPE has In-Reply-To but never References, so dropping the header section
        // altogether would silently break reply threading.
        #expect(LiveMailClient.detailOptions.contains(.fullHeader))
        #expect(LiveMailClient.detailHeaderFields == nil)
    }

    @Test func theNamedFieldListIsTheShapeThatWentWrong() {
        // What the message screen used to send, kept here so the difference is visible: the
        // field name goes out quoted, which is the token Mail2000 quotes a second time.
        let old = FetchMessageInfoRequest.wireCommand(
            options: LiveMailClient.summaryOptions,
            headerFields: ["References"]
        )
        #expect(old.contains(#"BODY.PEEK[HEADER.FIELDS ("References")]"#))
    }

    // MARK: Failing soft

    @Test func aProtocolErrorRetriesTheDetailFetchWithoutTheHeaderSection() throws {
        // Even with the request fixed, no decode failure anywhere in this path may stop the user
        // reading their mail: the fetch is retried without the header section and the message
        // opens without its thread chain.
        let decodeError = try Self.decodeFailure(Self.mail2000Echo)
        #expect(LiveMailClient.detailRetriesWithoutHeaderSection(after: decodeError))
        #expect(LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.protocolError("NO")))
    }

    @Test func aFailureASecondFetchCannotFixIsNotRetried() {
        // Retrying these would only delay an error the user has to see anyway.
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.unreachable))
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.authenticationFailed))
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.certificateRejected))
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.serverBusy))
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.folderChanged))
    }

    @Test func theFallbackFetchIsTheOneTheMessageListAlreadySucceedsWith() {
        // The retry must not carry a header section of any kind — it is the list's own fetch.
        let fallback = FetchMessageInfoRequest.wireCommand(options: LiveMailClient.summaryOptions)
        #expect(!fallback.contains("BODY.PEEK[HEADER"))
        #expect(!fallback.contains("\""))
    }
}
#endif
