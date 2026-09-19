#if os(iOS)
import Foundation
import SwiftMail

nonisolated extension MailTLSVerifier {
    /// Handed to SwiftMail's `IMAPServer` and `SMTPServer`; see the vendored copy's `.custom` policy.
    static let swiftMailVerifier = MailCertificateVerifier(identifier: "org.ntust.app.TigerDuck.spki-pins") { derChain, host in
        MailTLSVerifier.verify(derChain: derChain, host: host)
    }
}

/// Installs the Appendix A.5 charset rules into SwiftMail's RFC 2047 decoder, which
/// decodes sender names and subjects out of the IMAP ENVELOPE.
nonisolated enum SchoolMailCharsetHook {
    static func install() {
        MailCharsetResolver.setResolver { MailCharset.encoding(forLabel: $0) }
    }

    /// Exposes SwiftMail's header decoder to tests without importing SwiftMail there.
    static func decodeHeader(_ header: String) -> String {
        header.decodeMIMEHeader()
    }
}

/// `MailClient` over SwiftMail for mail.ntust.edu.tw (design doc §8). One IMAP connection
/// held for the actor's lifetime; SMTP connects per send. Both verify TLS through
/// `MailTLSVerifier`.
///
/// Which host, port and transport each of those uses comes from `MailServerConfig`, captured
/// once at `init`. That is the school's §1.1 configuration in every Release build; a DEBUG
/// build can point it elsewhere from Settings → Developer → Email, and everything below this
/// line is written for Mail2000 regardless.
///
/// Mail2000 has no MOVE, UIDPLUS, IDLE or SPECIAL-USE, so none of SwiftMail's helpers for
/// those are used; `MailMover` composes COPY/STORE/EXPUNGE itself.
///
/// Held-connection lifecycle (controller ruling): every `run` call is serialized against every
/// other one by `commandLock` (an `AsyncSerialLock`), so a command's SELECT and the
/// STORE/COPY/EXPUNGE it guards can never be interleaved by a different call's SELECT running on
/// the same shared connection. Inside that lock: a command probes the connection with a cheap
/// NOOP first (never a folder-reselecting STATUS); a dead connection is replaced with exactly one
/// reconnect-and-relogin, then the caller's command runs exactly once and to completion — even a
/// caller whose surrounding `Task` was since cancelled, because SwiftMail's own IMAP commands
/// ignore task cancellation, and stopping a multi-step operation like `MailMover.move` partway
/// through (after COPY but before STORE, or after STORE but before the ownership check that
/// guards EXPUNGE) is worse than letting it finish: a command that may already have started
/// (COPY, STORE, APPEND, EXPUNGE, a streaming download) is never retried, but it is also never
/// abandoned mid-flight. A network or certificate failure closes the underlying socket so the
/// next use reconnects from scratch; a protocol error or `.searchUnsupported` leaves the socket
/// alone. `logout()` always closes and never waits on `commandLock` — a long-running command
/// must not be able to block it — but it still queues behind whatever command is currently
/// in-flight at the SwiftMail level, since every `IMAPConnection` command (LOGOUT and
/// disconnect/done included) runs through that connection's own single `commandQueue`. A
/// reconnect or a live-connection NOOP probe that completes after `logout()` ran detects that
/// (via `connectionGeneration`) and closes what it has instead of handing an authenticated or
/// stale-but-open connection to `body()`. Connection *lifetime* beyond that (idle-close timing,
/// holding the connection open across a screen's multiple operations) belongs to whatever owns
/// the page session, not to this type — this file does not implement or expose an idle-close
/// primitive.
actor LiveMailClient: MailClient {
    nonisolated static let summaryOptions: FetchMessageInfoOptions = [.envelope, .internalDate, .flags, .size, .bodyStructure]

    /// The message screen's fetch: the summary attributes plus the **full** header section.
    ///
    /// ENVELOPE carries `In-Reply-To` but never `References`, and SwiftMail fills
    /// `MessageInfo.references` only from a fetched header section, so the detail fetch has to
    /// ask for one or every reply loses its thread chain. It asks with `.fullHeader`
    /// (`BODY.PEEK[HEADER]`) and never with a named field list. `headerFields: ["References"]`
    /// encodes as `BODY.PEEK[HEADER.FIELDS ("References")]` — well-formed IMAP, with the field
    /// name quoted as an `astring` — but Mail2000 echoes that section back uppercased *and*
    /// quoted a second time: `BODY[HEADER.FIELDS (""REFERENCES"")]`. NIOIMAP reads the leading
    /// `""` as an empty quoted string, then meets a bare `REFERENCES` where the closing `)`
    /// belongs, and the entire FETCH response fails to decode. On a real device that made every
    /// message open fail while the list — which never asked for a header section — loaded fine.
    /// `HEADER` has no parenthesised list in it for a server to mangle.
    ///
    /// `MailFetchSectionTests` pins the encoded request, and reproduces the server's echo
    /// through NIOIMAP's own client pipeline.
    nonisolated static let detailOptions: FetchMessageInfoOptions = summaryOptions.union(.fullHeader)

    /// Always `nil` — see `detailOptions`. A named constant rather than an omitted argument so
    /// the shape of the request the message screen sends is pinned by a test.
    nonisolated static let detailHeaderFields: [String]? = nil

    private let imap: IMAPServer
    private var credentials: (studentID: String, password: String)?
    /// Bumped, together with clearing `credentials`, as the very first thing `logout()` does —
    /// before its first `await` — so both changes are visible atomically to anything that reads
    /// them afterward. `ensureLiveConnection()` captures this in the same synchronous step as
    /// reading `credentials`, then checks it again after every `await` that precedes handing the
    /// connection to `body()` (a successful NOOP probe, and a successful reconnect+login): a
    /// mismatch means `logout()` ran while this method was suspended, so whatever was just
    /// confirmed-alive or freshly opened is closed and this throws instead of leaving an
    /// authenticated or stale-but-open connection behind for a session that already ended.
    private var connectionGeneration = 0
    /// Serializes whole `run` bodies — including the liveness probe/reconnect — against each
    /// other (rule D). Plain actor isolation only excludes *synchronous* execution; it does not
    /// stop one call's SELECT and the STORE/COPY/EXPUNGE it guards from being interleaved by a
    /// second call's SELECT at the `await` in between, since suspension points let other work
    /// scheduled on this actor run. A page that shares one client between its 60 s poll and the
    /// message screen could otherwise have `expunge(Trash)` SELECT Trash, an interleaved
    /// `setFlag(.seen, INBOX)` SELECT INBOX read-write, and then EXPUNGE remove INBOX's
    /// `\Deleted` mail — including another client's — instead of Trash's (spec §8.3). A private
    /// instance, not the raw lock methods, so no other code in the module can call `release()`
    /// on this specific client's lock; see `AsyncSerialLock`'s own tests for the lock's
    /// properties (FIFO order, no interleaving, releases after a throw).
    private let commandLock = AsyncSerialLock()

    /// The server this client talks to, resolved once at construction so the IMAP connection
    /// and the SMTP connections `send` opens can never disagree about it — and so a
    /// configuration change that arrives mid-session cannot move a live connection out from
    /// under a command. A change signs out (`DevMailServerSettings`), which discards the
    /// client, and the next one is built against the new configuration.
    private let config: MailServerConfig

    init(config: MailServerConfig = .effective) {
        self.config = config
        imap = IMAPServer(
            host: config.imapHost,
            port: config.imapPort,
            // `.custom` is kept whatever the scheme is. NIOSSL only consults a verification
            // callback when there is a TLS handler to consult it from, so this is the pinning
            // check on an implicit-TLS or STARTTLS connection and simply unreachable on a
            // plaintext one — there is no branch here that could drop the check on a
            // connection that does have TLS.
            transportSecurity: config.imapScheme.swiftMailTransportSecurity,
            certificateVerificationPolicy: .custom(MailTLSVerifier.swiftMailVerifier),
            minimumTLSVersion: .tlsv12
        )
    }

    func login(studentID: String, password: String) async throws {
        do {
            try await imap.connect()
            try await imap.login(username: studentID, password: password)
            credentials = (studentID, password)
        } catch {
            // Never leave a previous successful login's credentials in place after a failed
            // (re)login attempt — otherwise a later command would silently reconnect as the old
            // account instead of surfacing that this login failed.
            credentials = nil
            try? await imap.disconnect()
            throw Self.map(error)
        }
    }

    /// Never waits on `commandLock` (a long-running command must not be able to block logout),
    /// but LOGOUT and the disconnect that follows still queue behind whatever command is
    /// currently in flight at the SwiftMail level — `IMAPConnection.executeCommand`,
    /// `.connect()`, `.done()` and `.disconnect()` all run through that connection's own single
    /// `commandQueue`. Bumps `connectionGeneration` and clears `credentials` together, as the
    /// very first thing this does, before any `await`: a reconnect already in flight inside some
    /// other queued/running `run` call reads the new generation the moment it next checks (see
    /// `ensureLiveConnection`) and closes what it opened instead of leaving it authenticated
    /// under a session this call already ended.
    func logout() async {
        connectionGeneration += 1
        credentials = nil
        try? await imap.logout()
        try? await imap.disconnect()
    }

    func listFolders() async throws -> [String] {
        try await run { try await self.imap.listMailboxes().filter(\.isSelectable).map(\.name) }
    }

    func status(folder: String) async throws -> MailboxStatusInfo {
        try await run {
            // RFC 3501 §6.3.10: a server SHOULD NOT accept STATUS for the mailbox that's
            // currently selected, so STATUS is issued before EXAMINE, never after. A server that
            // rejects STATUS outright (`IMAPError.commandFailed`) just means no unseen count;
            // any other failure (a dropped connection, a malformed response) is a real problem
            // and propagates through `map` like every other error here.
            let unseen: Int?
            do {
                unseen = try await self.imap.mailboxStatus(folder).unseenCount
            } catch let error as IMAPError {
                switch error {
                case .commandFailed: unseen = nil
                default: throw error
                }
            }
            // `IMAPServer.mailboxStatus` only requests STATUS's UIDNEXT/UIDVALIDITY when the
            // server advertises UIDPLUS, even though both are base RFC 3501 STATUS items —
            // Mail2000 has no UIDPLUS (global-constraints.md), so that STATUS would never
            // carry them. EXAMINE's SELECT response always carries them unconditionally
            // (the same source `page(folder:...)` already uses below), so that's the source
            // of truth here.
            let selection = try await self.imap.examineMailbox(folder)
            return MailboxStatusInfo(
                uidValidity: selection.uidValidity.value,
                uidNext: selection.uidNext.value,
                unseen: unseen
            )
        }
    }

    func page(folder: String, olderThanSequence: Int?, pageSize: Int) async throws -> MailFolderPage {
        try await run {
            let selection = try await self.imap.examineMailbox(folder)
            let total = selection.messageCount
            let upper = min((olderThanSequence ?? total + 1) - 1, total)
            guard upper >= 1 else {
                return MailFolderPage(folder: folder, uidValidity: selection.uidValidity.value,
                                      messageCount: total, summaries: [], oldestLoadedSequence: nil)
            }
            let lower = max(1, upper - pageSize + 1)
            let infos = try await self.imap.fetchMessageInfos(
                sequenceRange: SequenceNumber(lower)...SequenceNumber(upper),
                options: Self.summaryOptions
            )
            let summaries = infos.compactMap(Self.summary(from:)).filter { !$0.isDeleted }.sorted { $0.uid > $1.uid }
            return MailFolderPage(folder: folder, uidValidity: selection.uidValidity.value, messageCount: total,
                                  summaries: summaries, oldestLoadedSequence: lower > 1 ? lower : nil)
        }
    }

    func summaries(folder: String, fromUID: UInt32) async throws -> [MailSummary] {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
            let infos = try await self.imap.fetchMessageInfos(
                uidRange: UID(fromUID)..., options: [.envelope, .internalDate, .flags, .size]
            )
            return infos.compactMap(Self.summary(from:))
        }
    }

    func summaries(folder: String, uids: [UInt32]) async throws -> [MailSummary] {
        guard !uids.isEmpty else { return [] }
        return try await run {
            _ = try await self.imap.examineMailbox(folder)
            let infos = try await self.imap.fetchMessageInfosBulk(using: Self.uidSet(uids), options: Self.summaryOptions)
            return infos.compactMap(Self.summary(from:))
        }
    }

    func flags(folder: String, uids: ClosedRange<UInt32>, expectedUIDValidity: UInt32?) async throws -> [UInt32: MailFlags] {
        try await run {
            let selection = try await self.imap.examineMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            let infos = try await self.imap.fetchMessageInfos(
                uidRange: UID(uids.lowerBound)...UID(uids.upperBound), options: [.flags]
            )
            var result: [UInt32: MailFlags] = [:]
            for info in infos {
                guard let uid = info.uid?.value else { continue }
                result[uid] = MailFlags(seen: info.flags.contains(.seen),
                                        answered: info.flags.contains(.answered),
                                        deleted: info.flags.contains(.deleted))
            }
            return result
        }
    }

    func detail(folder: String, uid: UInt32, expectedUIDValidity: UInt32?) async throws -> MailMessageDetail {
        try await run {
            let selection = try await self.imap.examineMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            guard let info = try await self.detailInfo(folder: folder, uid: uid, expectedUIDValidity: expectedUIDValidity),
                  let summary = Self.summary(from: info) else {
                throw MailClientError.protocolError("message \(uid) not found")
            }
            // The server described its own message in a way no IMAP parser can read, so there
            // are no parts to fetch and every branch below would be skipped. Fetch the message
            // whole and parse the MIME here instead — what Android has always done, and the only
            // thing left that can tell this mail from an empty one. Not `self.rawSource(...)`:
            // that takes `commandLock`, which this call already holds.
            if Self.recoversByLocalParse(info) {
                let raw = try await self.imap.fetchRawMessage(identifier: UID(uid))
                if let local = Self.localDetail(summary: summary, info: info, raw: raw) { return local }
                // The local parse found no more than the server's structure did. Fall through:
                // the message really does have nothing to show, and the screen says so.
            }
            var textBody: String?
            var htmlBody: String?
            var inlineImages: [String: MailInlineImage] = [:]
            for part in info.parts where !Self.isAttachment(part) {
                let type = part.contentType.lowercased()
                if type.hasPrefix("text/plain"), textBody == nil {
                    let data = try await self.imap.fetchAndDecodeMessagePartData(messageInfo: info, part: part)
                    textBody = MailCharset.decode(data, label: part.declaredCharset)
                } else if type.hasPrefix("text/html"), htmlBody == nil {
                    let data = try await self.imap.fetchAndDecodeMessagePartData(messageInfo: info, part: part)
                    htmlBody = MailCharset.decode(data, label: part.declaredCharset)
                } else if type.hasPrefix("image/"), let cid = part.contentId,
                          (part.size ?? 0) <= MailConstants.maxInlineImageBytes {
                    let data = try await self.imap.fetchAndDecodeMessagePartData(messageInfo: info, part: part)
                    inlineImages[Self.bareContentID(cid)] = MailInlineImage(mimeType: type, data: data)
                }
            }
            return MailMessageDetail(
                summary: summary,
                messageID: info.messageId.map(Self.angleBracketed),
                inReplyTo: info.inReplyTo.map(Self.angleBracketed),
                references: info.references?.map(Self.angleBracketed),
                returnPath: Self.returnPath(from: info),
                parts: info.parts.map(Self.bodyPart(from:)),
                textBody: textBody,
                htmlBody: htmlBody,
                inlineImages: inlineImages.isEmpty ? nil : inlineImages
            )
        }
    }

    /// The detail fetch, best-effort about the header section that carries `References`.
    ///
    /// Threading is worth a header section; it is not worth the message. If the fetch that asks
    /// for one comes back as a protocol error — including a response this client could not
    /// decode, which is exactly what a server that mangles the section it echoes back produces —
    /// this retries with the plain summary attributes the message list already fetches
    /// successfully every time, and the message opens without its thread chain instead of not
    /// opening at all. The same shape as the server-side search falling back when Mail2000
    /// refuses the query, and the compose screen's best-effort Reply-To lookup.
    ///
    /// Network, TLS, authentication, busy-server and UIDVALIDITY failures are *not* retried: a
    /// second fetch cannot fix any of them, and hiding them behind a partial message would be
    /// wrong. A decode failure makes SwiftMail recycle the connection, so the retry re-EXAMINEs
    /// the folder first — the reconnect that follows has no mailbox selected.
    private func detailInfo(folder: String, uid: UInt32, expectedUIDValidity: UInt32?) async throws -> MessageInfo? {
        do {
            return try await imap.fetchMessageInfo(
                for: UID(uid), options: Self.detailOptions, headerFields: Self.detailHeaderFields
            )
        } catch {
            guard Self.detailRetriesWithoutHeaderSection(after: error) else { throw error }
            // The retry re-EXAMINEs, so it gets its own SELECT response and is pinned against it
            // like the first one: the reconnect this path exists for is exactly where a folder
            // recreated server-side would first become visible.
            let selection = try await imap.examineMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            return try await imap.fetchMessageInfo(for: UID(uid), options: Self.summaryOptions)
        }
    }

    /// Whether a failed detail fetch is worth retrying without the header section. Only a
    /// protocol error is — every other `MailClientError` names something a second fetch cannot
    /// change.
    nonisolated static func detailRetriesWithoutHeaderSection(after error: any Error) -> Bool {
        if case .protocolError = map(error) { return true }
        return false
    }

    /// Whether this fetch's answer is one only a local MIME parse can rescue, and whether the
    /// message is small enough to be worth downloading whole for it.
    ///
    /// **Only on the unusable-structure path.** A message that genuinely has no parts — the same
    /// empty `parts` seen from the outside — must never start a whole-message download, so this
    /// keys off `MessageInfo.bodyStructureUnusable` (vendored patch 6) and nothing weaker. The
    /// normal path stays exactly as fast as it was.
    ///
    /// The ceiling is `MailConstants.maxLocalParseBytes`, measured against `RFC822.SIZE`, which
    /// both `detailOptions` and the `summaryOptions` fallback already ask for — so it is known
    /// before a single body byte is fetched. A server that answers no size at all is *not*
    /// treated as oversized: an absent attribute is not evidence of a large message, and reading
    /// it that way would let a server switch the whole recovery off by omitting one field, which
    /// is precisely the class of server this exists for.
    nonisolated static func recoversByLocalParse(_ info: MessageInfo) -> Bool {
        guard info.bodyStructureUnusable else { return false }
        guard let size = info.size else { return true }
        return size <= MailConstants.maxLocalParseBytes
    }

    /// A `MailMessageDetail` built from the message's own bytes rather than the server's
    /// description of them, via SwiftMail's offline `EMLParser` — the same parser
    /// `LiveMailClientParsingTests` runs the shared `.eml` corpus through.
    ///
    /// Everything that does not come from the structure — summary, Message-ID, thread chain,
    /// `Return-Path` — still comes from the fetch, which succeeded; only the body did not.
    /// `hasAttachments` is recomputed, because the summary was built from the empty part list.
    ///
    /// Returns nil when the parse yields nothing to show either: the caller then falls through
    /// to the ordinary (empty) result, so "the server's structure was unusable" never turns into
    /// a claim that a body was recovered.
    nonisolated static func localDetail(summary: MailSummary, info: MessageInfo, raw: Data) -> MailMessageDetail? {
        guard let message = try? EMLParser.parse(raw) else { return nil }
        var textBody: String?
        var htmlBody: String?
        var inlineImages: [String: MailInlineImage] = [:]
        for part in message.parts where !isAttachment(part) {
            let type = part.contentType.lowercased()
            if type.hasPrefix("text/plain"), textBody == nil {
                textBody = decodedText(of: part)
            } else if type.hasPrefix("text/html"), htmlBody == nil {
                htmlBody = decodedText(of: part)
            } else if type.hasPrefix("image/"), let cid = part.contentId,
                      (part.data?.count ?? 0) <= MailConstants.maxInlineImageBytes,
                      let data = part.decodedData() {
                inlineImages[bareContentID(cid)] = MailInlineImage(mimeType: type, data: data)
            }
        }
        let hasAttachments = message.parts.contains(where: isAttachment)
        guard textBody != nil || htmlBody != nil || hasAttachments else { return nil }
        var summary = summary
        summary.hasAttachments = hasAttachments
        return MailMessageDetail(
            summary: summary,
            messageID: info.messageId.map(angleBracketed),
            inReplyTo: info.inReplyTo.map(angleBracketed),
            references: info.references?.map(angleBracketed),
            returnPath: returnPath(from: info),
            parts: message.parts.map(bodyPart(from:)),
            textBody: textBody,
            htmlBody: htmlBody,
            inlineImages: inlineImages.isEmpty ? nil : inlineImages
        )
    }

    /// Transfer-decode a locally parsed part, then apply the app's Appendix A.5 charset rules —
    /// the same two steps `detail` applies to a part fetched from the server
    /// (`fetchAndDecodeMessagePartData` + `MailCharset.decode`), in the same order.
    nonisolated static func decodedText(of part: MessagePart) -> String? {
        guard let data = part.decodedData() else { return nil }
        return MailCharset.decode(data, label: part.declaredCharset)
    }

    func rawSource(folder: String, uid: UInt32) async throws -> Data {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
            return try await self.imap.fetchRawMessage(identifier: UID(uid))
        }
    }

    /// One part's bytes, by the section the attachment list was built from.
    ///
    /// Asks for `.size` as well as `.bodyStructure` only so `recoversByLocalParse`'s ceiling can
    /// be evaluated on the fallback below; it costs one integer per message.
    ///
    /// Pinned against this call's own EXAMINE response, like `detail` — the caller's pinned
    /// detail fetch says nothing about the generation *this* connection is looking at by the time
    /// the parts are asked for. The local-parse fallback further down re-fetches the whole
    /// message but never re-EXAMINEs, so it reads the very selection this assert checked and
    /// needs no second one; `detailInfo`'s retry does need its own only because the decode
    /// failure it recovers from makes SwiftMail reconnect with no mailbox selected.
    func attachment(folder: String, uid: UInt32, part: MailBodyPart, expectedUIDValidity: UInt32?) async throws -> Data {
        try await run {
            let selection = try await self.imap.examineMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            guard let info = try await self.imap.fetchMessageInfo(for: UID(uid), options: [.bodyStructure, .size]) else {
                throw MailClientError.protocolError("message \(uid) not found")
            }
            if let found = info.parts.first(where: { $0.section.description == part.section }) {
                return try await self.imap.fetchAndDecodeMessagePartData(messageInfo: info, part: found)
            }
            // The sections this attachment list was built from came from a local parse, because
            // the server's structure was unreadable (`detail`). There is nothing to fetch a
            // section *of*, so the same parse has to serve the bytes too — otherwise the fix
            // above would put attachments on screen that no tap could ever open.
            guard Self.recoversByLocalParse(info) else {
                throw MailClientError.protocolError("part \(part.section) not found")
            }
            let raw = try await self.imap.fetchRawMessage(identifier: UID(uid))
            guard let message = try? EMLParser.parse(raw),
                  let found = message.parts.first(where: { $0.section.description == part.section }),
                  let data = found.decodedData() else {
                throw MailClientError.protocolError("part \(part.section) not found")
            }
            return data
        }
    }

    func search(folder: String, query: String) async throws -> [UInt32] {
        try await run {
            do {
                _ = try await self.imap.examineMailbox(folder)
                // The SORT/ESEARCH variants need capabilities Mail2000 lacks; this plain
                // SEARCH is the one that works (the vendored patch adds CHARSET UTF-8 for Chinese).
                let found = try await self.rawSearch(
                    criteria: [.or(.or(.from(query), .subject(query)), .body(query))]
                )
                return found.toArray().map(\.value)
            } catch let error as IMAPError {
                throw Self.mapSearchError(error)
            }
        }
    }

    func setFlag(_ flag: MailFlag, on: Bool, folder: String, uids: [UInt32], expectedUIDValidity: UInt32?) async throws {
        guard !uids.isEmpty else { return }
        try await run {
            let selection = try await self.imap.selectMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            try await self.imap.store(flags: [flag.swiftMailFlag], on: Self.uidSet(uids), operation: on ? .add : .remove)
        }
    }

    func copy(folder: String, uids: [UInt32], to target: String, expectedUIDValidity: UInt32) async throws {
        guard !uids.isEmpty else { return }
        try await run {
            let selection = try await self.imap.selectMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            try await self.imap.copy(messages: Self.uidSet(uids), to: target)
        }
    }

    func deletedUIDs(folder: String, expectedUIDValidity: UInt32) async throws -> Set<UInt32> {
        try await run {
            let selection = try await self.imap.examineMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            let found = try await self.rawSearch(criteria: [.deleted])
            return Set(found.toArray().map(\.value))
        }
    }

    func expunge(folder: String, expectedUIDValidity: UInt32) async throws {
        try await run {
            let selection = try await self.imap.selectMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            try await self.imap.expunge()
        }
    }

    /// `IMAPServer.createMailbox` sends the name as raw bytes (`MailboxName(ByteBuffer(string:))`)
    /// after `resolveMailboxPath` has applied any advertised personal-namespace prefix, so the
    /// modified-UTF-7 name the caller passes is exactly what reaches the wire — the same spelling
    /// `listFolders()` reports back and `selectMailbox`/`copy`/`append` already take.
    func createFolder(_ name: String) async throws {
        try await run { try await self.imap.createMailbox(name) }
    }

    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws {
        try await run {
            // SwiftMail's IMAP `append` only accepts a `String` (IMAPServer+Append.swift has no
            // Data-based overload). `MailMessageBuilder.build` always returns `Data(string.utf8)`
            // — valid UTF-8 by construction, not necessarily 7-bit ASCII (RFC 2047-encoded
            // headers and quoted-printable bodies are ASCII, but addresses, In-Reply-To and
            // References go out as raw UTF-8) — so decoding it back with `String(decoding:as:
            // UTF8.self)` is lossless for every builder-produced payload.
            try await self.imap.append(rawMessage: String(decoding: message, as: UTF8.self), to: folder,
                                       flags: flags.map(\.swiftMailFlag), internalDate: nil)
        }
    }

    /// Wrapped in the same `mapSearchError` as `search(folder:query:)`, and for the same reason:
    /// nothing in Mail2000's CAPABILITY banner promises `SEARCH HEADER "Message-ID"` is honoured,
    /// so a server that refuses the key must come back as `.searchUnsupported` — the typed "this
    /// server will not answer that" — rather than as a raw `IMAPError` flattened into a generic
    /// `.protocolError`. The sent-copy dedupe (`SentCopyFiler`) turns either into
    /// `SentCopyProbe.unknown`, but only one of them says which of the two happened.
    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool {
        try await run {
            do {
                _ = try await self.imap.examineMailbox(folder)
                let found = try await self.rawSearch(criteria: [.header("Message-ID", messageID)])
                return !found.isEmpty
            } catch let error as IMAPError {
                throw Self.mapSearchError(error)
            }
        }
    }

    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        guard let credentials else { throw MailClientError.authenticationFailed }
        let smtp = SMTPServer(
            host: config.smtpHost,
            port: config.smtpPort,
            transportSecurity: config.smtpScheme.swiftMailTransportSecurity,
            certificateVerificationPolicy: .custom(MailTLSVerifier.swiftMailVerifier),
            minimumTLSVersion: .tlsv12
        )
        do {
            try await smtp.connect()
            try await smtp.login(username: credentials.studentID, password: credentials.password)
            try await smtp.sendRawMessage(message, from: EmailAddress(address: sender),
                                          to: recipients.map { EmailAddress(address: $0) })
            try? await smtp.disconnect()
        } catch {
            try? await smtp.disconnect()
            throw Self.map(error)
        }
    }

    // MARK: Helpers

    /// The one place `IMAPServer.search(criteria:)` is actually called.
    ///
    /// **This call is deliberate, and the vendored copy no longer marks it deprecated**
    /// (VENDORED.md entry 9) — the reasoning below is why, and it is the reason the annotation
    /// was dropped rather than the warning simply tolerated. SwiftMail suggests `extendedSearch(...)`
    /// (ESEARCH, RFC 4731) or `search(..., sortCriteria:)` (SORT), and Mail2000 advertises
    /// neither — its measured banner is
    /// `IMAP4 IMAP4rev1 AUTH=LOGIN LITERAL+ ID NAMESPACE STARTTLS` (design doc §1.2, taken from
    /// a real logged-in session), with no `ESEARCH`, `SORT` or `WITHIN` in it:
    ///
    /// - `search(..., sortCriteria:)` throws `commandNotSupported("SORT command not supported
    ///   by server")` before sending anything, so it cannot be used here at all.
    /// - `extendedSearch(...)` would degrade to a plain SEARCH (`useEsearch` is gated on the
    ///   capability), but it sends that SEARCH as `ExtendedSearchCommand` through a different
    ///   response handler — a wire and parsing path nothing has ever exercised against this
    ///   server — in exchange for no behaviour this app wants. `deletedUIDs` and
    ///   `containsMessageID` below are load-bearing (the §8.3 pre-EXPUNGE check and the
    ///   sent-copy dedupe), so "probably equivalent" is not a good enough reason to move them.
    ///
    /// `SearchCommand` is also the variant vendored patch 3 teaches to send `CHARSET UTF-8` for
    /// Chinese queries, so moving off it would silently regress those searches. Revisit only if
    /// the server's CAPABILITY banner changes.
    private func rawSearch(criteria: [SearchCriteria]) async throws -> MessageIdentifierSet<UID> {
        try await imap.search(criteria: criteria)
    }

    /// Runs one command against the held IMAP connection, serialized against every other `run`
    /// call by `commandLock`: probes liveness with a cheap NOOP (never a folder-reselecting
    /// STATUS), reconnects-and-relogs-in exactly once if the probe fails, then runs `body`
    /// exactly once, to completion — never retried, and never abandoned partway through either,
    /// since `body` may already have sent a command (COPY, STORE, APPEND, EXPUNGE, a streaming
    /// download) that must not be sent twice, and a multi-step caller like `MailMover.move`
    /// relies on each step it starts actually finishing. SwiftMail's own IMAP commands ignore
    /// task cancellation regardless, so there is nothing to gain and real safety to lose by
    /// checking it here. A network or certificate failure closes the socket so the next call
    /// reconnects from scratch; every other error leaves it alone. Acquires `commandLock`
    /// directly with explicit `acquire()`/`release()` calls (not `withLock`) so `body` keeps
    /// running with this actor's own isolation the whole time — it reads `self`-isolated state
    /// (`imap`, `credentials`, `connectionGeneration`) throughout.
    @discardableResult
    private func run<T>(_ body: () async throws -> T) async throws -> T {
        await commandLock.acquire()
        do {
            try await ensureLiveConnection()
            let result = try await body()
            await commandLock.release()
            return result
        } catch {
            let mapped = Self.map(error)
            if Self.closesConnectionOnFailure(mapped) {
                try? await imap.disconnect()
            }
            await commandLock.release()
            throw mapped
        }
    }

    private func ensureLiveConnection() async throws {
        guard let credentials else {
            throw MailClientError.protocolError("not logged in")
        }
        // Captured in the same synchronous step as reading `credentials` above, before any
        // `await` in this method: `logout()` bumps this and clears `credentials` together,
        // atomically from this method's point of view, so a mismatch found after any `await`
        // below means a `logout()` call landed somewhere in between.
        let generationAtStart = connectionGeneration

        if await imap.isConnected {
            var probeSucceeded = false
            do {
                _ = try await imap.noop()
                probeSucceeded = true
            } catch {
                try? await imap.disconnect()
            }
            if probeSucceeded {
                guard connectionGeneration == generationAtStart else {
                    try? await imap.disconnect()
                    throw MailClientError.protocolError("not logged in")
                }
                return
            }
        }

        do {
            try await imap.connect()
        } catch {
            try? await imap.disconnect()
            throw error
        }
        do {
            try await imap.login(username: credentials.studentID, password: credentials.password)
        } catch {
            // Only an actual authentication rejection means these credentials no longer work.
            // A timeout, dropped connection or "too many connections" mid-reconnect must not
            // clear them — otherwise the held client would answer "not logged in" until closed
            // even though the password is still fine: a background page poll would silently stop
            // and `send()` would misreport a transient failure as an authentication one. A
            // half-completed reconnect (connected but never authenticated) must still not be
            // left for the next call's NOOP probe to mistake for a live, usable session, so the
            // socket is always torn down here regardless of which case this was.
            if Self.map(error) == .authenticationFailed {
                self.credentials = nil
            }
            try? await imap.disconnect()
            throw error
        }
        guard connectionGeneration == generationAtStart else {
            // `logout()` ran mid-reconnect: this socket is now authenticated under a session
            // that already ended. Close it rather than handing it to `body()`.
            try? await imap.disconnect()
            throw MailClientError.protocolError("not logged in")
        }
    }

    /// Whether the UIDVALIDITY this command's own SELECT/EXAMINE just returned still matches the
    /// generation the caller pinned its UIDs to. `nil` — a caller that holds no pin — is never a
    /// mismatch.
    ///
    /// The expected value is always supplied by the caller and never read back out of state this
    /// actor shares between commands. An earlier version compared against a dictionary that every
    /// `status(folder:)` call rewrote, and the app's own 60 s page poll calls `status(INBOX)` on
    /// this same client: a folder recreated server-side mid-move had its new UIDVALIDITY written
    /// there by the poll, after which the guard compared the new value against itself and passed —
    /// COPY, STORE `\Deleted` and EXPUNGE then ran against UIDs that addressed entirely different
    /// messages. Passing the pin in as an argument makes that interleaving unrepresentable.
    nonisolated static func uidValidityChanged(expected: UInt32?, current: UInt32) -> Bool {
        guard let expected else { return false }
        return expected != current
    }

    nonisolated static func assertUIDValidity(expected: UInt32?, current: UInt32) throws {
        guard !uidValidityChanged(expected: expected, current: current) else {
            throw MailClientError.folderChanged
        }
    }

    nonisolated static func closesConnectionOnFailure(_ error: MailClientError) -> Bool {
        switch error {
        case .unreachable, .certificateRejected: true
        case .authenticationFailed, .serverBusy, .searchUnsupported, .folderChanged, .protocolError: false
        }
    }

    nonisolated private static func uidSet(_ uids: [UInt32]) -> MessageIdentifierSet<UID> {
        MessageIdentifierSet<UID>(uids.map { UID($0) })
    }

    nonisolated static func map(_ error: any Error) -> MailClientError {
        if let mailError = error as? MailClientError { return mailError }
        if let imapError = error as? IMAPError {
            switch imapError {
            case .loginFailed(let text): return classifyLoginFailure(text)
            case .authFailed, .unsupportedAuthMechanism: return .authenticationFailed
            case .timeout: return .unreachable
            case .connectionFailed(let reason): return classify(reason, fallback: .unreachable)
            default: return classify(String(describing: imapError), fallback: .protocolError(String(describing: imapError)))
            }
        }
        if let smtpError = error as? SMTPError {
            switch smtpError {
            case .authenticationFailed: return .authenticationFailed
            case .tlsFailed: return .certificateRejected
            case .connectionFailed(let reason): return classify(reason, fallback: .unreachable)
            default: return classify(String(describing: smtpError), fallback: .protocolError(String(describing: smtpError)))
            }
        }
        if let sendError = error as? SMTPSendError {
            // Thrown by `sendRawMessage` for every failure once MAIL FROM has been
            // dispatched (a rejected recipient, a dropped connection mid-transaction, a
            // submission timeout) — by far the common send-failure shape. Falls back to
            // `.protocolError` (carrying the server's reply/reason), not `.unreachable`,
            // since most of these are not network failures.
            return classify(String(describing: sendError), fallback: .protocolError(String(describing: sendError)))
        }
        // A response this client could not read. Checked before the text heuristics below so a
        // decoder error can never be bucketed by whatever happens to appear in its buffer dump.
        if isDecodeFailure(error) { return .protocolError(String(describing: error)) }
        // Nothing above recognized this error. `.unreachable` used to be the fallback here, and
        // that is why a parser bug looked like a network outage: an `IMAPDecoderError` arrives
        // as a type this module cannot even name, became `.unreachable` → `LoginError.network`
        // → "Can't reach the mail server", and the device's mail was unreadable with a working
        // network. Errors that genuinely mean "couldn't reach the server" are named above
        // (`IMAPError.timeout`, `connectionFailed`) or are network-shaped in the sense
        // `isNetworkShaped` describes; an unknown error that is neither is far likelier to be a
        // protocol problem, so it says so instead of blaming the network.
        let described = String(describing: error)
        return classify(described, fallback: isNetworkShaped(error) ? .unreachable : .protocolError(described))
    }

    /// A failure of the IMAP/SMTP response decoder or its parser — the server sent something
    /// this client cannot read.
    ///
    /// NIOIMAP surfaces these as `IMAPDecoderError` (wrapping a `ParserError`) straight from the
    /// channel and SwiftMail rethrows them untouched, but SwiftMail does not re-export NIOIMAP,
    /// so the type cannot be named here. Matched by name instead — the same way SwiftMail's own
    /// `shouldRecycleConnection` recognizes it.
    nonisolated static func isDecodeFailure(_ error: any Error) -> Bool {
        let text = (String(describing: type(of: error)) + " " + String(describing: error)).lowercased()
        return text.contains("decodererror") || text.contains("parsererror")
    }

    /// Errors that really do mean the server could not be reached, for the shapes that reach
    /// `map(_:)` unrecognized: Foundation's URL and POSIX transport errors, and NIO's own
    /// connection/channel/IO failures. `.unreachable` is reserved for these — it is also the
    /// only classification besides `.certificateRejected` that tears the connection down.
    nonisolated static func isNetworkShaped(_ error: any Error) -> Bool {
        let domain = (error as NSError).domain
        if domain == NSURLErrorDomain || domain == NSPOSIXErrorDomain { return true }
        let name = String(describing: type(of: error)).lowercased()
        return name.contains("connectionerror") || name.contains("channelerror") || name.contains("ioerror")
    }

    /// `.commandFailed`/`.commandNotSupported` from a server-issued SEARCH means the server
    /// refused the query outright (Mail2000 can reject search keys it doesn't support); every
    /// other `IMAPError` isn't search-specific and maps through the general `map(_:)`.
    nonisolated static func mapSearchError(_ error: IMAPError) -> MailClientError {
        switch error {
        case .commandFailed, .commandNotSupported: .searchUnsupported
        default: map(error)
        }
    }

    /// SwiftMail turns every tagged NO/BAD reply to LOGIN into `IMAPError.loginFailed(text)`
    /// (`LoginHandler.handleTaggedErrorResponse`), with no distinction between a wrong password
    /// and the server temporarily refusing new sessions — a LOGIN NO for "too many connections"
    /// looks identical in shape to a rejected password. Only the RFC 5530 response codes a
    /// server actually uses to say "temporarily unavailable, try later" (`[UNAVAILABLE]`,
    /// `[LIMIT]`, `[INUSE]`) or the literal phrase Mail2000 sends for its connection cap count as
    /// `.serverBusy`; every other LOGIN failure — including generic phrasing like "try again"
    /// that a wrong-password reply could just as easily contain — stays `.authenticationFailed`.
    nonisolated static func classifyLoginFailure(_ text: String) -> MailClientError {
        let lowered = text.lowercased()
        let busyResponseCodes = ["[unavailable]", "[limit]", "[inuse]"]
        if busyResponseCodes.contains(where: lowered.contains) { return .serverBusy }
        if lowered.contains("too many connections") { return .serverBusy }
        return .authenticationFailed
    }

    /// TLS certificate/verification failures surface as NIOSSL handshake errors that mention
    /// the certificate; a busy server as NO/BYE text. A handshake failure that does *not*
    /// mention a certificate (e.g. a protocol-version alert) is a transport problem, not a
    /// trust one, and falls through to whatever `fallback` the caller passed — `.unreachable`
    /// for a raw connection failure, `.protocolError(...)` for an otherwise-unrecognized
    /// `IMAPError`/`SMTPError`/`SMTPSendError` — rather than being misreported as
    /// `.certificateRejected`.
    nonisolated static func classify(_ text: String, fallback: MailClientError) -> MailClientError {
        let lowered = text.lowercased()
        if lowered.contains("certificate") { return .certificateRejected }
        if lowered.contains("too many") || lowered.contains("busy") || lowered.contains("try again later") { return .serverBusy }
        if lowered.contains("authenticationfailed") || lowered.contains("login failed") { return .authenticationFailed }
        return fallback
    }

    nonisolated static func summary(from info: MessageInfo) -> MailSummary? {
        guard let uid = info.uid?.value else { return nil }
        // `parseSender`, not `parseList().first`: a From whose address has no domain
        // (`"Mail Deliver System" <MAILER-DAEMON>`, every Mail2000 bounce) still yields its
        // display name, with an empty address. `mailNonEmpty` then stores that as `nil`
        // rather than `""`, so `isExternal` below stays false — there is no domain to call
        // outside — instead of badging every delivery-failure notice as an outside sender.
        //
        // This is also the whole of what the *list* can know: it is built from ENVELOPE, which
        // carries no `Return-Path`, so "no domain at all" is the weaker signal it decides the
        // badge on. The opened message reads the real one — see `MailWarnings.isBounce`, which
        // records why the two sites differ and why asking the server for named header fields is
        // not an option here.
        let sender = info.from.flatMap { MailAddress.parseSender($0) }
        let fromAddress = sender.flatMap { MailTextCleaner.clean($0.address).mailNonEmpty }
        let clean: (String) -> String = { MailTextCleaner.clean(RFC2047.decode($0)) }
        return MailSummary(
            uid: uid,
            fromName: sender?.name.map(clean),
            fromAddress: fromAddress,
            to: info.to.map(clean),
            cc: info.cc.map(clean),
            subject: info.subject.map(clean),
            date: info.date ?? info.internalDate,
            isSeen: info.flags.contains(.seen),
            isAnswered: info.flags.contains(.answered),
            isDeleted: info.flags.contains(.deleted),
            size: info.size,
            hasAttachments: info.parts.contains(where: isAttachment),
            isExternal: fromAddress.map { !MailWarnings.isSchoolDomain(MailWarnings.domain(ofAddress: $0)) } ?? false
        )
    }

    /// `Return-Path` off the full header section `detailOptions` already fetches — nil when the
    /// fetch fell back to the summary attributes (`detailInfo`), which carry no headers at all.
    ///
    /// The **first** one, not the last. The final delivery agent prepends its `Return-Path`
    /// above everything the sender wrote, so a message carrying extra copies lower down is one
    /// where the top line is the server's and the rest are the sender's. `additionalFields` is
    /// the same headers as a dictionary and keeps the *last* value for a repeated name, which is
    /// the wrong end; this reads the ordered list instead.
    nonisolated static func returnPath(from info: MessageInfo) -> String? {
        info.additionalHeaderFields?.first { $0.name.lowercased() == "return-path" }?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func isAttachment(_ part: MessagePart) -> Bool {
        let type = part.contentType.lowercased()
        if part.disposition?.lowercased() == "attachment" { return true }
        if type.hasPrefix("multipart/") { return false }
        if type.hasPrefix("text/plain") || type.hasPrefix("text/html") { return part.filename != nil }
        if type.hasPrefix("image/"), part.contentId != nil { return false }
        return true
    }

    nonisolated static func bodyPart(from part: MessagePart) -> MailBodyPart {
        MailBodyPart(
            section: part.section.description,
            contentType: part.contentType.lowercased(),
            charset: part.declaredCharset,
            transferEncoding: part.encoding,
            filename: part.filename.map { MailTextCleaner.clean(RFC2047.decode($0)) },
            contentID: part.contentId.map(bareContentID),
            // `size` is BODYSTRUCTURE's octet count, which a part from a local parse
            // (`localDetail`) has none of — its own still-encoded bytes are the same measure.
            size: part.size ?? part.data?.count,
            isAttachment: isAttachment(part)
        )
    }

    nonisolated static func bareContentID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    nonisolated static func angleBracketed(_ id: MessageID) -> String {
        let text = String(describing: id)
        return text.hasPrefix("<") ? text : "<\(text)>"
    }
}

/// The app's transport scheme in SwiftMail's own terms. Internal rather than private so
/// `MailServerConfigTests` can pin the mapping — this is the one step between what the
/// developer override says and what actually goes on the wire, and `.startTLS` mapping to
/// SwiftMail's
/// `.startTLS` (which resolves to `startTLSRequired`, not `startTLSIfAvailable`) is the part
/// worth holding still: a server that does not advertise STARTTLS fails the connection instead
/// of quietly continuing in the clear.
extension MailTransportScheme {
    nonisolated var swiftMailTransportSecurity: MailTransportSecurity {
        switch self {
        case .implicitTLS: .implicitTLS
        case .startTLS: .startTLS
        case .plaintext: .plainText
        }
    }

    /// The mapping as a string, so a test can pin it without importing SwiftMail — the same
    /// reason `SchoolMailCharsetHook.decodeHeader` exists. Nothing in the app reads this.
    nonisolated var swiftMailTransportSecurityName: String {
        String(describing: swiftMailTransportSecurity)
    }
}

private extension MailFlag {
    nonisolated var swiftMailFlag: SwiftMail.Flag {
        switch self {
        case .seen: .seen
        case .answered: .answered
        case .deleted: .deleted
        case .draft: .draft
        }
    }
}
#endif
