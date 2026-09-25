import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

/// TigerDuck patch 6 — a `BODYSTRUCTURE` the parser cannot read must not look like a message
/// with no parts.
///
/// NIOIMAP already refuses to fail a whole FETCH over a server's bad `BODYSTRUCTURE`: it wraps
/// the attribute in `MessageAttribute.BodyStructure`, whose own documentation says the point of
/// the wrapper is *"servers sometimes generate invalid BODY structures … rather than fail the
/// entire message parsing, this wrapper allows distinguishing between valid and invalid
/// BODYSTRUCTURE data."* `FetchMessageInfoHandler` matched only `.valid` and let `.invalid` fall
/// into `default: break`, so that distinction died one layer above the parser: `MessageInfo.parts`
/// came back empty, with no error and no log, and a caller could not tell it apart from a message
/// that genuinely has no parts. A client that wants to recover such a message (by fetching it
/// whole and parsing the MIME itself) has to be able to ask.
///
/// Nothing below is a stand-in: the responses go through `IMAPClientHandler` and the real
/// `FetchMessageInfoHandler`, the same pair a live fetch installs.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct InvalidBodyStructureTests {

    // MARK: Server responses

    /// A `BODYSTRUCTURE` whose multipart parameter list ends in a bare, unquoted token where the
    /// grammar requires a string. Constructed to be unparseable, *not* a claim about what any
    /// particular server emits: the point of the fix is that the client survives whatever the
    /// server got wrong, and the parenthesis-balance skip NIOIMAP falls back to is the same one
    /// for every malformation.
    static let unparseableStructure = #"""
    (("text" "plain" ("charset" "UTF-8") NIL NIL "7bit" 210 6)\#
    ("message" "rfc822" NIL NIL NIL "7bit" 29360128) "mixed" \#
    ("BOUNDARY" ---xSlk6?OEkwsMzDd4=o4fchcYwdj))
    """#

    /// The same shape, written the way RFC 3501 says it should be — the control for every
    /// assertion below.
    static let validStructure = #"""
    (("text" "plain" ("charset" "UTF-8") NIL NIL "7bit" 210 6)\#
    ("application" "octet-stream" ("name" "recording.m4a") NIL NIL "base64" 29360128) "mixed" \#
    ("boundary" "---xSlk6?OEkwsMzDd4=o4fchcYwdj"))
    """#

    static func fetchResponse(bodyStructure: String?) -> String {
        let attributes = ["UID 4242", "RFC822.SIZE 29400000"]
            + (bodyStructure.map { ["BODYSTRUCTURE \($0)"] } ?? [])
        return "* 1 FETCH (\(attributes.joined(separator: " ")))\r\n"
    }

    // MARK: What the parser does with it

    @Test("NIOIMAP reports an unreadable BODYSTRUCTURE as `.invalid` rather than failing the FETCH")
    func anUnparseableStructureDecodesAsInvalid() throws {
        #expect(try Self.bodyAttribute(Self.unparseableStructure) == .invalid)
        // The control: the well-formed spelling of the same message is `.valid`.
        guard case .valid = try Self.bodyAttribute(Self.validStructure) else {
            Issue.record("the RFC-conforming structure must parse")
            return
        }
    }

    // MARK: What the handler does with it

    @Test("An unusable structure is surfaced, and leaves `parts` empty")
    func anUnparseableStructureIsReportedAsUnusable() async throws {
        let infos = try await Self.executeFetch(bodyStructure: Self.unparseableStructure)
        let info = try #require(infos.first)
        // Still empty — there is nothing to build parts *from*. The fix is that this is no
        // longer the only thing a caller can see.
        #expect(info.parts.isEmpty)
        #expect(info.bodyStructureUnusable)
        // The rest of the FETCH is unaffected: a bad BODYSTRUCTURE costs the structure, not
        // the message.
        #expect(info.uid == UID(4242))
        #expect(info.size == 29_400_000)
    }

    @Test("A valid structure is not reported as unusable")
    func aValidStructureIsNotReportedAsUnusable() async throws {
        let infos = try await Self.executeFetch(bodyStructure: Self.validStructure)
        let info = try #require(infos.first)
        #expect(!info.bodyStructureUnusable)
        #expect(info.parts.map(\.contentType) == ["text/plain; charset=UTF-8", "application/octet-stream"])
    }

    @Test("A fetch that never asked for a BODYSTRUCTURE is not reported as unusable")
    func anAbsentStructureIsNotReportedAsUnusable() async throws {
        // Otherwise every `.slim`/`.uidFlagsOnly` fetch would claim the server misbehaved.
        let infos = try await Self.executeFetch(bodyStructure: nil)
        let info = try #require(infos.first)
        #expect(!info.bodyStructureUnusable)
        #expect(info.parts.isEmpty)
    }

    @Test("The flag round-trips, and an older encoding without it decodes as usable")
    func theFlagIsCodable() throws {
        var info = MessageInfo(sequenceNumber: SequenceNumber(1))
        info.bodyStructureUnusable = true
        let encoded = try JSONEncoder().encode(info)
        #expect(try JSONDecoder().decode(MessageInfo.self, from: encoded).bodyStructureUnusable)

        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "bodyStructureUnusable")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try !JSONDecoder().decode(MessageInfo.self, from: legacy).bodyStructureUnusable)
    }

    // MARK: Harness

    /// Decode one untagged FETCH through NIOIMAP's own client pipeline and return the `BODY`
    /// attribute it produced.
    static func bodyAttribute(_ structure: String) throws -> MessageAttribute.BodyStructure {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        try channel.pipeline.syncOperations.addHandler(IMAPClientHandler())
        try channel.writeInbound(ByteBuffer(string: fetchResponse(bodyStructure: structure)))
        while let next = ((try? channel.readInbound(as: Response.self)) ?? nil) {
            guard case .fetch(let fetch) = next, case .simpleAttribute(let attribute) = fetch,
                  case .body(let body, _) = attribute else { continue }
            return body
        }
        Issue.record("no BODY attribute in the decoded response")
        throw EMLParserError.invalidData
    }

    /// Drive the real `FetchMessageInfoHandler` the way `IMAPServer.fetchMessageInfo` does.
    static func executeFetch(bodyStructure: String?) async throws -> [MessageInfo] {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: [MessageInfo].self)
        let handler = FetchMessageInfoHandler(commandTag: "A001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let command = TaggedCommand(tag: "A001", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        for raw in [fetchResponse(bodyStructure: bodyStructure), "A001 OK FETCH completed\r\n"] {
            var buffer = channel.allocator.buffer(capacity: raw.utf8.count)
            buffer.writeString(raw)
            try await channel.writeInbound(buffer)
        }
        return try await promise.futureResult.get()
    }
}
