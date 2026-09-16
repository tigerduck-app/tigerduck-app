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
/// Mail2000 has no MOVE, UIDPLUS, IDLE or SPECIAL-USE, so none of SwiftMail's helpers for
/// those are used; `MailMover` composes COPY/STORE/EXPUNGE itself.
///
/// Held-connection lifecycle (controller ruling): every command probes the connection with a
/// cheap NOOP first (never a folder-reselecting STATUS); a dead connection is replaced with
/// exactly one reconnect-and-relogin, then the caller's command runs exactly once — a command
/// that may already have started (COPY, STORE, APPEND, EXPUNGE, a streaming download) is never
/// retried. A network or certificate failure closes the underlying socket so the next use
/// reconnects from scratch; a protocol error or `.searchUnsupported` leaves the socket alone.
/// `logout()` always closes. Connection *lifetime* beyond that (idle-close timing, holding the
/// connection open across a screen's multiple operations) belongs to whatever owns the page
/// session, not to this type — this file does not implement or expose an idle-close primitive.
actor LiveMailClient: MailClient {
    nonisolated private static let summaryOptions: FetchMessageInfoOptions = [.envelope, .internalDate, .flags, .size, .bodyStructure]

    private let imap: IMAPServer
    private var credentials: (studentID: String, password: String)?
    /// The UIDVALIDITY the most recent `status(folder:)` call observed for each folder. `copy`,
    /// `setFlag` and `expunge` compare this against the SELECT response on the connection that
    /// is about to run them, and refuse before sending anything if the folder was recreated
    /// server-side in between (rule d) — `status()`'s own EXAMINE and a mutating call's SELECT
    /// can land on different reconnects of this actor's single held connection, so the value has
    /// to be remembered here rather than trusted from whatever `MailMover.assertFolderUnchanged`
    /// read moments earlier on a connection that may no longer be the one in use.
    private var lastKnownUIDValidity: [String: UInt32] = [:]

    init() {
        imap = IMAPServer(
            host: MailConstants.host,
            port: MailConstants.imapPort,
            transportSecurity: .implicitTLS,
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

    func logout() async {
        try? await imap.logout()
        try? await imap.disconnect()
        credentials = nil
        lastKnownUIDValidity.removeAll()
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
            self.lastKnownUIDValidity[folder] = selection.uidValidity.value
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

    func flags(folder: String, uids: ClosedRange<UInt32>) async throws -> [UInt32: MailFlags] {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
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

    func detail(folder: String, uid: UInt32) async throws -> MailMessageDetail {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
            // ENVELOPE never carries References (only In-Reply-To); SwiftMail only fills
            // `MessageInfo.references` from a fetched header section, so it has to be requested
            // explicitly here or every reply loses the thread chain.
            guard let info = try await self.imap.fetchMessageInfo(
                    for: UID(uid), options: Self.summaryOptions, headerFields: ["References"]
                  ),
                  let summary = Self.summary(from: info) else {
                throw MailClientError.protocolError("message \(uid) not found")
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
                parts: info.parts.map(Self.bodyPart(from:)),
                textBody: textBody,
                htmlBody: htmlBody,
                inlineImages: inlineImages.isEmpty ? nil : inlineImages
            )
        }
    }

    func rawSource(folder: String, uid: UInt32) async throws -> Data {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
            return try await self.imap.fetchRawMessage(identifier: UID(uid))
        }
    }

    func attachment(folder: String, uid: UInt32, part: MailBodyPart) async throws -> Data {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
            guard let info = try await self.imap.fetchMessageInfo(for: UID(uid), options: [.bodyStructure]),
                  let found = info.parts.first(where: { $0.section.description == part.section }) else {
                throw MailClientError.protocolError("part \(part.section) not found")
            }
            return try await self.imap.fetchAndDecodeMessagePartData(messageInfo: info, part: found)
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

    func setFlag(_ flag: MailFlag, on: Bool, folder: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await run {
            let selection = try await self.imap.selectMailbox(folder)
            guard !Self.uidValidityChanged(remembered: self.lastKnownUIDValidity[folder], current: selection.uidValidity.value) else {
                throw MailClientError.folderChanged
            }
            try await self.imap.store(flags: [flag.swiftMailFlag], on: Self.uidSet(uids), operation: on ? .add : .remove)
        }
    }

    func copy(folder: String, uids: [UInt32], to target: String) async throws {
        guard !uids.isEmpty else { return }
        try await run {
            let selection = try await self.imap.selectMailbox(folder)
            guard !Self.uidValidityChanged(remembered: self.lastKnownUIDValidity[folder], current: selection.uidValidity.value) else {
                throw MailClientError.folderChanged
            }
            try await self.imap.copy(messages: Self.uidSet(uids), to: target)
        }
    }

    func deletedUIDs(folder: String) async throws -> Set<UInt32> {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
            let found = try await self.rawSearch(criteria: [.deleted])
            return Set(found.toArray().map(\.value))
        }
    }

    func expunge(folder: String) async throws {
        try await run {
            let selection = try await self.imap.selectMailbox(folder)
            guard !Self.uidValidityChanged(remembered: self.lastKnownUIDValidity[folder], current: selection.uidValidity.value) else {
                throw MailClientError.folderChanged
            }
            try await self.imap.expunge()
        }
    }

    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws {
        try await run {
            // SwiftMail's IMAP `append` only accepts a `String` (IMAPServer+Append.swift has no
            // Data-based overload). Every caller builds `message` through `MailMessageBuilder`,
            // which always quoted-printable- or base64-encodes the body and RFC 2047-encodes
            // non-ASCII headers, so the payload is 7-bit ASCII by construction and decoding it as
            // UTF-8 below is lossless (ASCII is a UTF-8 subset). Assert the invariant so a future
            // caller that breaks it fails loudly in debug/test builds instead of silently losing
            // bytes to `String(decoding:as:)`'s replacement-character behavior.
            assert(message.allSatisfy { $0 < 0x80 }, "append() payload must be 7-bit ASCII (MailMessageBuilder's contract)")
            try await self.imap.append(rawMessage: String(decoding: message, as: UTF8.self), to: folder,
                                       flags: flags.map(\.swiftMailFlag), internalDate: nil)
        }
    }

    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
            let found = try await self.rawSearch(criteria: [.header("Message-ID", messageID)])
            return !found.isEmpty
        }
    }

    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        guard let credentials else { throw MailClientError.authenticationFailed }
        let smtp = SMTPServer(
            host: MailConstants.host,
            port: MailConstants.smtpPort,
            transportSecurity: .implicitTLS,
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

    /// The one place `IMAPServer.search(criteria:)` (deprecated — Mail2000 has no SORT/ESEARCH,
    /// so this remains the only search variant it supports) is actually called, so the build
    /// shows a single deprecation warning instead of one per call site.
    private func rawSearch(criteria: [SearchCriteria]) async throws -> MessageIdentifierSet<UID> {
        try await imap.search(criteria: criteria)
    }

    /// Runs one command against the held IMAP connection: probes liveness with a cheap
    /// NOOP (never a folder-reselecting STATUS), reconnects-and-relogs-in exactly once if
    /// the probe fails, then runs `body` exactly once — never retried, since `body` may be
    /// a command (COPY, STORE, APPEND, EXPUNGE, a streaming download) that must not be sent
    /// twice. A network or certificate failure closes the socket so the next call
    /// reconnects from scratch; every other error leaves it alone.
    @discardableResult
    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            try await ensureLiveConnection()
            return try await body()
        } catch {
            let mapped = Self.map(error)
            if Self.closesConnectionOnFailure(mapped) {
                try? await imap.disconnect()
            }
            throw mapped
        }
    }

    private func ensureLiveConnection() async throws {
        guard let credentials else {
            throw MailClientError.protocolError("not logged in")
        }
        if await imap.isConnected {
            do {
                _ = try await imap.noop()
                return
            } catch {
                try? await imap.disconnect()
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
            // A reconnect-login that the server rejects means these credentials no longer work —
            // clear them so the next call fails fast with `.protocolError("not logged in")`
            // instead of retrying the same bad password forever. A half-completed reconnect
            // (connected but never authenticated) must also not be left for the next call's NOOP
            // probe to mistake for a live, usable session.
            self.credentials = nil
            try? await imap.disconnect()
            throw error
        }
    }

    /// Whether the folder's connection-fresh UIDVALIDITY no longer matches the value the most
    /// recent `status(folder:)` call recorded for that folder. `nil` (nothing recorded yet)
    /// never counts as a mismatch — the caller relies on a different layer
    /// (`MailMover.assertFolderUnchanged`, which always calls `status()` first) having already
    /// checked in that case.
    nonisolated static func uidValidityChanged(remembered: UInt32?, current: UInt32) -> Bool {
        guard let remembered else { return false }
        return remembered != current
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
            case .loginFailed, .authFailed, .unsupportedAuthMechanism: return .authenticationFailed
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
        return classify(String(describing: error), fallback: .unreachable)
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

    /// TLS certificate/verification failures surface as NIOSSL handshake errors that mention
    /// the certificate; a busy server as NO/BYE text. A handshake failure that does *not*
    /// mention a certificate (e.g. a protocol-version alert) is a transport problem, not a
    /// trust one, and falls through to `fallback` (`.unreachable` at every call site) rather
    /// than being misreported as `.certificateRejected`.
    nonisolated static func classify(_ text: String, fallback: MailClientError) -> MailClientError {
        let lowered = text.lowercased()
        if lowered.contains("certificate") { return .certificateRejected }
        if lowered.contains("too many") || lowered.contains("busy") || lowered.contains("try again later") { return .serverBusy }
        if lowered.contains("authenticationfailed") || lowered.contains("login failed") { return .authenticationFailed }
        return fallback
    }

    nonisolated static func summary(from info: MessageInfo) -> MailSummary? {
        guard let uid = info.uid?.value else { return nil }
        let sender = info.from.flatMap { MailAddress.parseList($0).first }
        let fromAddress = sender.map { MailTextCleaner.clean($0.address) }
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
            size: part.size,
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
