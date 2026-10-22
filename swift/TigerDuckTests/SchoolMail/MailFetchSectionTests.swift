#if os(iOS)
import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import SwiftMail
import Testing
@testable import TigerDuck

/// Why the message screen may never ask for a named header-field list, and why a response it
/// cannot decode must not be reported as an unreachable server.
///
/// SwiftMail sends `headerFields: ["References"]` as `BODY.PEEK[HEADER.FIELDS ("References")]`,
/// quoting the name as RFC 3501 allows. Mail2000 echoes the section uppercased and quoted again,
/// and the response stops being IMAP. The responses here go through `IMAPClientHandler`, the
/// NIO handler SwiftMail installs on its own channel, so a failing case produces the real
/// `IMAPDecoderError` that `LiveMailClient.map(_:)` receives.
struct MailFetchSectionTests {

    static func fetchResponse(section: String, literal: String) -> String {
        "* 1 FETCH (UID 4242 BODY[\(section)] {\(literal.utf8.count)}\r\n\(literal))\r\n"
    }

    static let headerBlock = "From: a@mail.ntust.edu.tw\r\nReferences: <first@ntust> <second@ntust>\r\n\r\n"

    static let mail2000Echo = fetchResponse(section: #"HEADER.FIELDS (""REFERENCES"")"#, literal: headerBlock)

    /// The same section echoed the way RFC 3501 says it should be — proving the request TigerDuck
    /// *sent* was well-formed and it is the server's re-quoting that breaks the response.
    static let conformingEcho = fetchResponse(section: #"HEADER.FIELDS ("References")"#, literal: headerBlock)

    /// `BODY.PEEK[HEADER]`'s echo, uppercased the way Mail2000 uppercases. There is no
    /// parenthesised list in it, so there is nothing for a server to re-quote.
    static let fullHeaderEcho = fetchResponse(section: "HEADER", literal: headerBlock)

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
        // `BODY.PEEK[HEADER]` arrives as a `.body` section of kind `.header` with the whole header
        // block. SwiftMail's `FetchMessageInfoHandler` collects only `.header`/`.headerFields`
        // and parses `References:` into `MessageInfo.references`: threading needs no field list.
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

    @Test func aDecodeFailureIsAProtocolErrorNotAnUnreachableServer() throws {
        let error = try Self.decodeFailure(Self.mail2000Echo)
        #expect(LiveMailClient.map(error) == .protocolError(String(describing: error)))
    }

    @Test func aSendWhoseAcceptanceIsUnknownIsUnconfirmed() {
        let ambiguous = SMTPSendError(phase: .content, acceptance: .ambiguous, reason: .connectionLost)
        let notAccepted = SMTPSendError(phase: .content, acceptance: .notAccepted, reason: .connectionLost)
        #expect(LiveMailClient.map(ambiguous) == .sendUnconfirmed)
        #expect(LiveMailClient.map(notAccepted) != .sendUnconfirmed)
    }

    @Test func genuinelyNetworkShapedErrorsStayUnreachable() {
        #expect(LiveMailClient.map(IMAPError.timeout) == .unreachable)
        #expect(LiveMailClient.map(IMAPError.connectionFailed("connection reset by peer")) == .unreachable)
        #expect(LiveMailClient.map(URLError(.notConnectedToInternet)) == .unreachable)
        #expect(LiveMailClient.map(URLError(.timedOut)) == .unreachable)
    }

    @Test func theDetailFetchSendsNoQuotedHeaderFieldList() {
        let command = FetchMessageInfoRequest.wireCommand(
            options: LiveMailClient.detailOptions,
            headerFields: LiveMailClient.detailHeaderFields
        )
        #expect(command.contains("BODY.PEEK[HEADER]"))
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
        let old = FetchMessageInfoRequest.wireCommand(
            options: LiveMailClient.summaryOptions,
            headerFields: ["References"]
        )
        #expect(old.contains(#"BODY.PEEK[HEADER.FIELDS ("References")]"#))
    }

    @Test func aProtocolErrorRetriesTheDetailFetchWithoutTheHeaderSection() throws {
        let decodeError = try Self.decodeFailure(Self.mail2000Echo)
        #expect(LiveMailClient.detailRetriesWithoutHeaderSection(after: decodeError))
        #expect(LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.protocolError("NO")))
    }

    @Test func aFailureASecondFetchCannotFixIsNotRetried() {
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.unreachable))
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.authenticationFailed))
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.certificateRejected))
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.serverBusy))
        #expect(!LiveMailClient.detailRetriesWithoutHeaderSection(after: MailClientError.folderChanged))
    }

    @Test func theFallbackFetchIsTheOneTheMessageListAlreadySucceedsWith() {
        let fallback = FetchMessageInfoRequest.wireCommand(options: LiveMailClient.summaryOptions)
        #expect(!fallback.contains("BODY.PEEK[HEADER"))
        #expect(!fallback.contains("\""))
    }
}
#endif
