#if os(iOS)
import Foundation
import SwiftMail

nonisolated extension MailTLSVerifier {
    static let swiftMailVerifier = MailCertificateVerifier(identifier: "org.ntust.app.TigerDuck.spki-pins") { derChain, host in
        MailTLSVerifier.verify(derChain: derChain, host: host)
    }
}

nonisolated enum SchoolMailCharsetHook {
    static func install() {
        MailCharsetResolver.setResolver { MailCharset.encoding(forLabel: $0) }
    }

    static func decodeHeader(_ header: String) -> String {
        header.decodeMIMEHeader()
    }
}

/// `MailClient` over SwiftMail for mail.ntust.edu.tw: one IMAP connection held for the actor's
/// lifetime, SMTP per send, both verified by `MailTLSVerifier`. Host, port and transport come
/// from `MailServerConfig` at `init`: the school's in Release, changeable in DEBUG (Settings →
/// Developer → Email); the code assumes Mail2000 either way. Mail2000 has no MOVE, UIDPLUS,
/// IDLE or SPECIAL-USE, so `MailMover` composes COPY/STORE/EXPUNGE itself. Commands are
/// serialized and run once, to completion (`run(_:)`); `logout()` bypasses that queue. How long
/// the connection stays open is up to the page session's owner, not this type.
/// See docs/decisions/0015-mail-held-imap-connection.md.
actor LiveMailClient: MailClient {
    nonisolated static let summaryOptions: FetchMessageInfoOptions = [.envelope, .internalDate, .flags, .size, .bodyStructure]

    /// The message screen's fetch: the summary attributes plus the full header section.
    ///
    /// ENVELOPE has `In-Reply-To` but not `References`, which SwiftMail reads only from a fetched
    /// header section, so without one every reply loses its thread chain. Ask with `.fullHeader`
    /// (`BODY.PEEK[HEADER]`), never a field list: Mail2000 echoes `HEADER.FIELDS ("References")`
    /// back as `HEADER.FIELDS (""REFERENCES"")`, which NIOIMAP cannot decode: every message would
    /// open only through `detailInfo`'s retry, without its thread chain. `HEADER` has no list to
    /// mangle. `MailFetchSectionTests` pins the request and replays the echo through NIOIMAP.
    nonisolated static let detailOptions: FetchMessageInfoOptions = summaryOptions.union(.fullHeader)

    nonisolated static let detailHeaderFields: [String]? = nil

    private let imap: IMAPServer
    private var credentials: (studentID: String, password: String)?
    private var connectionGeneration = 0
    private let commandLock = AsyncSerialLock()

    private let config: MailServerConfig

    init(config: MailServerConfig = .effective) {
        self.config = config
        imap = IMAPServer(
            host: config.imapHost,
            port: config.imapPort,
            // `.custom` whatever the scheme: NIOSSL consults the callback only when there is a TLS
            // handler, so it is the pinning check on implicit-TLS and STARTTLS connections and is
            // unreachable on plaintext. No branch here can drop the check from a TLS connection.
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
            credentials = nil
            try? await imap.disconnect()
            throw Self.map(error)
        }
    }

    /// Never waits on `commandLock`, so a long-running command cannot block logout. LOGOUT and the
    /// disconnect still queue behind the command in flight at the SwiftMail level:
    /// `IMAPConnection.executeCommand`, `.connect()`, `.done()` and `.disconnect()` all run through
    /// that connection's single `commandQueue`. Bumps `connectionGeneration` and clears
    /// `credentials` together, first, before any `await`: a reconnect in flight in another `run`
    /// call sees the new generation at its next check (`ensureLiveConnection`) and closes what it
    /// opened instead of leaving it authenticated under a session that has ended.
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
            // EXAMINE, not STATUS: `IMAPServer.mailboxStatus` asks STATUS for UIDNEXT and
            // UIDVALIDITY only when the server advertises UIDPLUS, which Mail2000 does not, and
            // EXAMINE's response always carries both, the same source `page(folder:...)` uses.
            let selection = try await self.imap.examineMailbox(folder)
            return MailboxStatusInfo(uidValidity: selection.uidValidity.value, uidNext: selection.uidNext.value)
        }
    }

    func page(folder: String, olderThanSequence: Int?, pageSize: Int) async throws -> MailFolderPage {
        try await run {
            let selection = try await self.imap.examineMailbox(folder)
            let total = selection.messageCount
            let upper = min((olderThanSequence ?? total + 1) - 1, total)
            guard upper >= 1 else {
                return MailFolderPage(folder: folder, uidValidity: selection.uidValidity.value,
                                      messageCount: total, summaries: [], oldestLoadedSequence: nil,
                                      uidNext: selection.uidNext.value)
            }
            let lower = max(1, upper - pageSize + 1)
            let infos = try await self.imap.fetchMessageInfos(
                sequenceRange: SequenceNumber(lower)...SequenceNumber(upper),
                options: Self.summaryOptions
            )
            let summaries = infos.compactMap(Self.summary(from:)).filter { !$0.isDeleted }.sorted { $0.uid > $1.uid }
            return MailFolderPage(folder: folder, uidValidity: selection.uidValidity.value, messageCount: total,
                                  summaries: summaries, oldestLoadedSequence: lower > 1 ? lower : nil,
                                  uidNext: selection.uidNext.value,
                                  windowUIDs: MailFolderPage.span(of: infos.compactMap { $0.uid?.value }))
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

    func summaries(folder: String, uids: [UInt32], expectedUIDValidity: UInt32?) async throws -> [MailSummary] {
        guard !uids.isEmpty else { return [] }
        return try await run {
            let selection = try await self.imap.examineMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
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

    func detail(folder: String, uid: UInt32, expectedUIDValidity: UInt32?, inlineImages includeImages: Bool) async throws -> MailMessageDetail {
        try await run {
            let selection = try await self.imap.examineMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            guard let info = try await self.detailInfo(folder: folder, uid: uid, expectedUIDValidity: expectedUIDValidity),
                  let summary = Self.summary(from: info) else {
                throw MailClientError.protocolError("message \(uid) not found")
            }
            if Self.recoversByLocalParse(info) {
                let raw = try await self.imap.fetchRawMessage(identifier: UID(uid))
                if let local = Self.localDetail(summary: summary, info: info, raw: raw) { return local }
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
                } else if includeImages, type.hasPrefix("image/"), let cid = part.contentId,
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
                replyTo: Self.replyTo(from: info),
                parts: info.parts.map(Self.bodyPart(from:)),
                textBody: textBody,
                htmlBody: htmlBody,
                inlineImages: inlineImages.isEmpty ? nil : inlineImages
            )
        }
    }

    /// The detail fetch, best-effort about the header section that carries `References`.
    ///
    /// Threading is worth a header section, not the message. If that fetch fails with a protocol
    /// error, an undecodable response included, this retries with the summary attributes the list
    /// already fetches, and the message opens without its thread chain. Network, TLS,
    /// authentication, busy-server and UIDVALIDITY failures are not retried: a second fetch cannot
    /// fix them, and a partial message would hide them. A decode failure makes SwiftMail recycle
    /// the connection, so the retry re-EXAMINEs first: the new connection has no mailbox selected.
    private func detailInfo(folder: String, uid: UInt32, expectedUIDValidity: UInt32?) async throws -> MessageInfo? {
        do {
            return try await imap.fetchMessageInfo(
                for: UID(uid), options: Self.detailOptions, headerFields: Self.detailHeaderFields
            )
        } catch {
            guard Self.detailRetriesWithoutHeaderSection(after: error) else { throw error }
            let selection = try await imap.examineMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            return try await imap.fetchMessageInfo(for: UID(uid), options: Self.summaryOptions)
        }
    }

    nonisolated static func detailRetriesWithoutHeaderSection(after error: any Error) -> Bool {
        if case .protocolError = map(error) { return true }
        return false
    }

    ///
    nonisolated static func recoversByLocalParse(_ info: MessageInfo) -> Bool {
        guard info.bodyStructureUnusable else { return false }
        guard let size = info.size else { return true }
        return size <= MailConstants.maxLocalParseBytes
    }

    ///
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
            replyTo: replyTo(from: info),
            parts: message.parts.map(bodyPart(from:)),
            textBody: textBody,
            htmlBody: htmlBody,
            inlineImages: inlineImages.isEmpty ? nil : inlineImages
        )
    }

    nonisolated static func decodedText(of part: MessagePart) -> String? {
        guard let data = part.decodedData() else { return nil }
        return MailCharset.decode(data, label: part.declaredCharset)
    }

    func rawSource(folder: String, uid: UInt32, expectedUIDValidity: UInt32?) async throws -> Data {
        try await run {
            let selection = try await self.imap.examineMailbox(folder)
            try Self.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            return try await self.imap.fetchRawMessage(identifier: UID(uid))
        }
    }

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

    func search(folder: String, query: String) async throws -> (uids: [UInt32], uidValidity: UInt32) {
        try await run {
            do {
                let selection = try await self.imap.examineMailbox(folder)
                // The SORT/ESEARCH variants need capabilities Mail2000 lacks; this plain
                // SEARCH is the one that works (the vendored patch adds CHARSET UTF-8 for Chinese).
                let found = try await self.rawSearch(
                    criteria: [.or(.or(.from(query), .subject(query)), .body(query))]
                )
                return (found.toArray().map(\.value), selection.uidValidity.value)
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
            // SwiftMail's IMAP `append` has no `Data` overload (IMAPServer+Append.swift).
            // `MailMessageBuilder.build` returns `Data(string.utf8)`, UTF-8 but not always ASCII
            // (addresses, In-Reply-To, References go out raw), so decoding it back is lossless.
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

    /// The one place `IMAPServer.search(criteria:)` is called, and plain SEARCH is a choice.
    /// Mail2000's measured banner, `IMAP4 IMAP4rev1 AUTH=LOGIN LITERAL+ ID NAMESPACE STARTTLS`,
    /// has no ESEARCH, SORT or WITHIN: `search(..., sortCriteria:)` throws before sending, and
    /// `extendedSearch(...)` would send SEARCH down a wire and parsing path never run against this
    /// server, for no gain. `deletedUIDs` (the pre-EXPUNGE check) and `containsMessageID` (the
    /// sent-copy dedupe) are load-bearing, and vendored patch 3 makes it send `CHARSET UTF-8` for
    /// Chinese queries. So the vendored copy drops its deprecation (VENDORED.md entry 9). Revisit
    /// only if the server's CAPABILITY banner changes.
    private func rawSearch(criteria: [SearchCriteria]) async throws -> MessageIdentifierSet<UID> {
        try await imap.search(criteria: criteria)
    }

    /// Runs one command on the held IMAP connection, serialized by `commandLock`. Probes liveness
    /// with a cheap NOOP (never a folder-reselecting STATUS), reconnects and logs in once if that
    /// fails, then runs `body` once, to completion. Never retried, since `body` may have sent a
    /// command that must not be sent twice (COPY, STORE, APPEND, EXPUNGE, a streaming download),
    /// and never abandoned, since `MailMover.move` relies on each step it starts finishing; the
    /// SwiftMail calls here ignore cancellation anyway. A network or certificate failure closes
    /// the socket so the next call reconnects; other errors leave it. Not `withLock`: `body` must
    /// keep this actor's isolation to read `imap`, `credentials` and `connectionGeneration`.
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
            if Self.map(error) == .authenticationFailed {
                self.credentials = nil
            }
            try? await imap.disconnect()
            throw error
        }
        guard connectionGeneration == generationAtStart else {
            try? await imap.disconnect()
            throw MailClientError.protocolError("not logged in")
        }
    }

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
        case .authenticationFailed, .serverBusy, .searchUnsupported, .folderChanged, .sendUnconfirmed,
             .protocolError: false
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
            if sendError.acceptance == .ambiguous { return .sendUnconfirmed }
            // `sendRawMessage` throws this for any failure after MAIL FROM (a rejected recipient,
            // a dropped connection mid-transaction, a timeout), the usual send failure. Most are
            // not network failures, so the fallback is `.protocolError`, not `.unreachable`.
            return classify(String(describing: sendError), fallback: .protocolError(String(describing: sendError)))
        }
        if isDecodeFailure(error) { return .protocolError(String(describing: error)) }
        let described = String(describing: error)
        return classify(described, fallback: isNetworkShaped(error) ? .unreachable : .protocolError(described))
    }

    /// A failure of the IMAP/SMTP response decoder or its parser — the server sent something
    /// this client cannot read.
    /// NIOIMAP surfaces these as `IMAPDecoderError` (wrapping a `ParserError`) straight from the
    /// channel and SwiftMail rethrows them untouched, but SwiftMail does not re-export NIOIMAP,
    /// so the type cannot be named here. Matched by name instead — the same way SwiftMail's own
    /// `shouldRecycleConnection` recognizes it.
    nonisolated static func isDecodeFailure(_ error: any Error) -> Bool {
        let text = (String(describing: type(of: error)) + " " + String(describing: error)).lowercased()
        return text.contains("decodererror") || text.contains("parsererror")
    }

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
        // `parseSender`, not `parseList().first`: a From with no domain, like every Mail2000 bounce
        // (`<MAILER-DAEMON>`), keeps its name, with a `nil` address, so `isExternal` stays false.
        // ENVELOPE has no `Return-Path`; the opened message checks it (`MailWarnings.isBounce`).
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
            isExternal: fromAddress.map { !MailWarnings.isSchoolDomain(MailWarnings.domain(ofAddress: $0)) } ?? false,
            arrivedAt: info.internalDate
        )
    }

    /// `Return-Path` off the full header section `detailOptions` already fetches — nil when the
    /// fetch fell back to the summary attributes (`detailInfo`), which carry no headers at all.
    /// The **first** one, not the last. The final delivery agent prepends its `Return-Path`
    /// above everything the sender wrote, so a message carrying extra copies lower down is one
    /// where the top line is the server's and the rest are the sender's. `additionalFields` is
    /// the same headers as a dictionary and keeps the *last* value for a repeated name, which is
    /// the wrong end; this reads the ordered list instead.
    nonisolated static func returnPath(from info: MessageInfo) -> String? {
        info.additionalHeaderFields?.first { $0.name.lowercased() == "return-path" }?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func replyTo(from info: MessageInfo) -> String? {
        guard let fields = info.additionalHeaderFields else { return nil }
        return fields.first { $0.name.lowercased() == "reply-to" }.map { RFC2047.decode($0.value) } ?? ""
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
