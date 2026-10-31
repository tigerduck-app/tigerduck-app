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
            throw MailIMAPErrors.map(error)
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
        try await run { try await MailIMAPCommands.status(folder: folder, imap: self.imap) }
    }

    func page(folder: String, olderThanSequence: Int?, pageSize: Int) async throws -> MailFolderPage {
        try await run {
            try await MailIMAPCommands.page(folder: folder, olderThanSequence: olderThanSequence, pageSize: pageSize, imap: self.imap)
        }
    }

    func summaries(folder: String, fromUID: UInt32) async throws -> [MailSummary] {
        try await run { try await MailIMAPCommands.summaries(folder: folder, fromUID: fromUID, imap: self.imap) }
    }

    func summaries(folder: String, uids: [UInt32], expectedUIDValidity: UInt32?) async throws -> [MailSummary] {
        guard !uids.isEmpty else { return [] }
        return try await run {
            try await MailIMAPCommands.summaries(folder: folder, uids: uids, expectedUIDValidity: expectedUIDValidity, imap: self.imap)
        }
    }

    func flags(folder: String, uids: ClosedRange<UInt32>, expectedUIDValidity: UInt32?) async throws -> [UInt32: MailFlags] {
        try await run {
            try await MailIMAPCommands.flags(folder: folder, uids: uids, expectedUIDValidity: expectedUIDValidity, imap: self.imap)
        }
    }

    func detail(folder: String, uid: UInt32, expectedUIDValidity: UInt32?, inlineImages includeImages: Bool) async throws -> MailMessageDetail {
        try await run {
            try await MailIMAPCommands.examine(folder, expecting: expectedUIDValidity, imap: self.imap)
            return try await MailIMAPFetch.detail(folder: folder, uid: uid, expectedUIDValidity: expectedUIDValidity,
                                                  includeImages: includeImages, imap: self.imap)
        }
    }

    func rawSource(folder: String, uid: UInt32, expectedUIDValidity: UInt32?) async throws -> Data {
        try await run {
            try await MailIMAPCommands.examine(folder, expecting: expectedUIDValidity, imap: self.imap)
            return try await self.imap.fetchRawMessage(identifier: UID(uid))
        }
    }

    func attachment(folder: String, uid: UInt32, part: MailBodyPart, expectedUIDValidity: UInt32?) async throws -> Data {
        try await run {
            try await MailIMAPCommands.examine(folder, expecting: expectedUIDValidity, imap: self.imap)
            return try await MailIMAPFetch.attachment(uid: uid, part: part, imap: self.imap)
        }
    }

    /// This and `searchTexts` feed the search index and yield the connection to every other
    /// command, so a mail the user opens waits for one fetch at most.
    /// See docs/decisions/0027-mail-local-search-index.md.
    func undeletedUIDs(folder: String) async throws -> (uids: [UInt32], uidValidity: UInt32) {
        try await run(yielding: true) { try await MailIMAPCommands.undeletedUIDs(folder: folder, imap: self.imap) }
    }

    func searchTexts(folder: String, uids: [UInt32], expectedUIDValidity: UInt32) async throws -> [UInt32: String] {
        guard !uids.isEmpty else { return [:] }
        return try await run(yielding: true) {
            try await MailIMAPCommands.searchTexts(folder: folder, uids: uids, expectedUIDValidity: expectedUIDValidity,
                                                   imap: self.imap) {
                try await self.stepAsideForWaitingCommands(folder: folder, expectedUIDValidity: expectedUIDValidity)
            }
        }
    }

    /// Called holding `commandLock` and returns holding it again, with the folder selected anew,
    /// since the command let through may have selected another.
    private func stepAsideForWaitingCommands(folder: String, expectedUIDValidity: UInt32) async throws {
        guard await commandLock.hasNonYieldingWaiters else { return }
        await commandLock.release()
        await commandLock.acquire(yielding: true)
        try await ensureLiveConnection()
        try await MailIMAPCommands.examine(folder, expecting: expectedUIDValidity, imap: imap)
    }

    func setFlag(_ flag: MailFlag, on: Bool, folder: String, uids: [UInt32], expectedUIDValidity: UInt32?) async throws {
        guard !uids.isEmpty else { return }
        try await run {
            try await MailIMAPCommands.setFlag(flag, on: on, folder: folder, uids: uids, expectedUIDValidity: expectedUIDValidity,
                                               imap: self.imap)
        }
    }

    func copy(folder: String, uids: [UInt32], to target: String, expectedUIDValidity: UInt32) async throws {
        guard !uids.isEmpty else { return }
        try await run {
            try await MailIMAPCommands.copy(folder: folder, uids: uids, to: target, expectedUIDValidity: expectedUIDValidity,
                                            imap: self.imap)
        }
    }

    func deletedUIDs(folder: String, expectedUIDValidity: UInt32) async throws -> Set<UInt32> {
        try await run {
            try await MailIMAPCommands.deletedUIDs(folder: folder, expectedUIDValidity: expectedUIDValidity, imap: self.imap)
        }
    }

    func expunge(folder: String, expectedUIDValidity: UInt32) async throws {
        try await run { try await MailIMAPCommands.expunge(folder: folder, expectedUIDValidity: expectedUIDValidity, imap: self.imap) }
    }

    /// `IMAPServer.createMailbox` sends the name as raw bytes (`MailboxName(ByteBuffer(string:))`)
    /// after `resolveMailboxPath` has applied any advertised personal-namespace prefix, so the
    /// modified-UTF-7 name the caller passes is exactly what reaches the wire — the same spelling
    /// `listFolders()` reports back and `selectMailbox`/`copy`/`append` already take.
    func createFolder(_ name: String) async throws {
        try await run { try await self.imap.createMailbox(name) }
    }

    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws {
        try await run { try await MailIMAPCommands.append(message, to: folder, flags: flags, imap: self.imap) }
    }

    func containsMessageID(_ messageID: String, in folder: String) async throws -> Bool {
        try await run { try await MailIMAPCommands.containsMessageID(messageID, in: folder, imap: self.imap) }
    }

    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        guard let credentials else { throw MailClientError.authenticationFailed }
        try await MailSMTP.send(message, from: sender, to: recipients, studentID: credentials.studentID,
                                password: credentials.password, config: config)
    }

    /// Runs one command on the held IMAP connection, serialized by `commandLock` (behind every other
    /// command when `yielding`). Probes liveness with a cheap NOOP (never a folder-reselecting
    /// STATUS), reconnects and logs in once if that fails, then runs `body` once, to completion.
    /// Never retried, since `body` may have sent a command that must not be sent twice (COPY, STORE,
    /// APPEND, EXPUNGE, a streaming download), and never abandoned, since `MailMover.move` relies on
    /// each step it starts finishing; the SwiftMail calls here ignore cancellation anyway. A network
    /// or certificate failure closes the socket so the next call reconnects; other errors leave it. Not
    /// `withLock`: `body` must keep the actor's isolation to read `imap`, `credentials` and the generation.
    @discardableResult
    private func run<T>(yielding: Bool = false, _ body: () async throws -> T) async throws -> T {
        await commandLock.acquire(yielding: yielding)
        do {
            try await ensureLiveConnection()
            let result = try await body()
            await commandLock.release()
            return result
        } catch {
            let mapped = MailIMAPErrors.map(error)
            if MailErrorClass(mapped).closesConnection {
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
            if MailIMAPErrors.map(error) == .authenticationFailed {
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

#endif