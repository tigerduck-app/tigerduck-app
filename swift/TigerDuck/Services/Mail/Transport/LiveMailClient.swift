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
/// Held-connection lifecycle (controller ruling, carried from the Android T12 reviews):
/// every command probes the connection with a cheap NOOP first (never a folder-reselecting
/// STATUS); a dead connection is replaced with exactly one reconnect-and-relogin, then the
/// caller's command runs exactly once — a command that may already have started (COPY,
/// STORE, APPEND, EXPUNGE, a streaming download) is never retried. A network or certificate
/// failure closes the underlying socket so the next use reconnects from scratch; a protocol
/// error or `.searchUnsupported` leaves the socket alone. `acquire()`/`release()` are the
/// primitive a screen that holds this client across multiple operations uses: `release()`
/// arms a ~30 s idle-close timer (re-armed by any further use that ends while still
/// released); `acquire()` cancels it. Nothing in this file calls `acquire()`/`release()`
/// itself — a later screen/session-holding task calls them.
actor LiveMailClient: MailClient {
    nonisolated private static let summaryOptions: FetchMessageInfoOptions = [.envelope, .internalDate, .flags, .size, .bodyStructure]

    private let imap: IMAPServer
    private var credentials: (studentID: String, password: String)?
    private var isAcquired = false
    private var idleCloseTask: Task<Void, Never>?

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
            try? await imap.disconnect()
            throw Self.map(error)
        }
        if !isAcquired { armIdleClose() }
    }

    func logout() async {
        cancelIdleClose()
        try? await imap.logout()
        try? await imap.disconnect()
        credentials = nil
        isAcquired = false
    }

    // MARK: Held-connection lifecycle

    /// Cancels the idle-close timer. Call when a screen that holds this client appears.
    func acquire() {
        isAcquired = true
        cancelIdleClose()
    }

    /// Marks this client as no longer actively held and arms the idle-close timer
    /// (`MailConstants.connectionIdleClose`, ~30 s). Any further use of the connection
    /// that completes while still released re-arms the timer, so a background check
    /// reusing this connection doesn't leave the socket open indefinitely.
    func release() {
        isAcquired = false
        armIdleClose()
    }

    private func cancelIdleClose() {
        idleCloseTask?.cancel()
        idleCloseTask = nil
    }

    private func armIdleClose() {
        cancelIdleClose()
        idleCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Int(MailConstants.connectionIdleClose)))
            guard !Task.isCancelled else { return }
            await self?.closeIfStillReleased()
        }
    }

    private func closeIfStillReleased() async {
        idleCloseTask = nil
        guard !isAcquired else { return }
        try? await imap.disconnect()
    }

    func listFolders() async throws -> [String] {
        try await run { try await self.imap.listMailboxes().filter(\.isSelectable).map(\.name) }
    }

    func status(folder: String) async throws -> MailboxStatusInfo {
        try await run {
            // `IMAPServer.mailboxStatus` only requests STATUS's UIDNEXT/UIDVALIDITY when the
            // server advertises UIDPLUS, even though both are base RFC 3501 STATUS items —
            // Mail2000 has no UIDPLUS (global-constraints.md), so that STATUS would never
            // carry them. EXAMINE's SELECT response always carries them unconditionally
            // (the same source `page(folder:...)` already uses below), so that's the source
            // of truth here; STATUS is used only for its best-effort unseen count.
            let selection = try await self.imap.examineMailbox(folder)
            let status = try? await self.imap.mailboxStatus(folder)
            return MailboxStatusInfo(
                uidValidity: selection.uidValidity.value,
                uidNext: selection.uidNext.value,
                unseen: status?.unseenCount
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
            guard let info = try await self.imap.fetchMessageInfo(for: UID(uid), options: Self.summaryOptions),
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
                let found: MessageIdentifierSet<UID> = try await self.imap.search(
                    criteria: [.or(.or(.from(query), .subject(query)), .body(query))]
                )
                return found.toArray().map(\.value)
            } catch let error as IMAPError {
                switch error {
                case .commandFailed, .commandNotSupported: throw MailClientError.searchUnsupported
                default: throw error
                }
            }
        }
    }

    func setFlag(_ flag: MailFlag, on: Bool, folder: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await run {
            _ = try await self.imap.selectMailbox(folder)
            try await self.imap.store(flags: [flag.swiftMailFlag], on: Self.uidSet(uids), operation: on ? .add : .remove)
        }
    }

    func copy(folder: String, uids: [UInt32], to target: String) async throws {
        guard !uids.isEmpty else { return }
        try await run {
            _ = try await self.imap.selectMailbox(folder)
            try await self.imap.copy(messages: Self.uidSet(uids), to: target)
        }
    }

    func deletedUIDs(folder: String) async throws -> Set<UInt32> {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
            let found: MessageIdentifierSet<UID> = try await self.imap.search(criteria: [.deleted])
            return Set(found.toArray().map(\.value))
        }
    }

    func expunge(folder: String) async throws {
        try await run {
            _ = try await self.imap.selectMailbox(folder)
            try await self.imap.expunge()
        }
    }

    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws {
        try await run {
            try await self.imap.append(rawMessage: String(decoding: message, as: UTF8.self), to: folder,
                                       flags: flags.map(\.swiftMailFlag), internalDate: nil)
        }
    }

    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool {
        try await run {
            _ = try await self.imap.examineMailbox(folder)
            let found: MessageIdentifierSet<UID> = try await self.imap.search(criteria: [.header("Message-ID", messageID)])
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

    /// Runs one command against the held IMAP connection: probes liveness with a cheap
    /// NOOP (never a folder-reselecting STATUS), reconnects-and-relogs-in exactly once if
    /// the probe fails, then runs `body` exactly once — never retried, since `body` may be
    /// a command (COPY, STORE, APPEND, EXPUNGE, a streaming download) that must not be sent
    /// twice. A network or certificate failure closes the socket so the next call
    /// reconnects from scratch; every other error leaves it alone. Whenever this client
    /// isn't currently held (`acquire()`/`release()`), finishing re-arms the idle-close
    /// timer, matching "any use that ends while released re-arms the ~30 s close."
    @discardableResult
    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            try await ensureLiveConnection()
            let result = try await body()
            if !isAcquired { armIdleClose() }
            return result
        } catch {
            let mapped = Self.map(error)
            if Self.closesConnectionOnFailure(mapped) {
                try? await imap.disconnect()
            }
            if !isAcquired { armIdleClose() }
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
            try await imap.login(username: credentials.studentID, password: credentials.password)
        } catch {
            // A half-completed reconnect (connected but never authenticated, e.g. the
            // password was rejected) must not be left for the next call's NOOP probe to
            // mistake for a live, usable session — tear it down so the next attempt starts
            // from a clean connect+login.
            try? await imap.disconnect()
            throw error
        }
    }

    nonisolated private static func closesConnectionOnFailure(_ error: MailClientError) -> Bool {
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

    /// TLS failures surface as NIOSSL handshake errors; a busy server as NO/BYE text.
    nonisolated static func classify(_ text: String, fallback: MailClientError) -> MailClientError {
        let lowered = text.lowercased()
        if lowered.contains("certificate") || lowered.contains("handshake") { return .certificateRejected }
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
