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
            // unreachable on plaintext.
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

    func logout() async {
        endSession()
        try? await imap.logout()
        try? await imap.disconnect()
    }

    private func endSession() {
        connectionGeneration += 1
        credentials = nil
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

    func undeletedUIDs(folder: String) async throws -> (uids: [UInt32], uidValidity: UInt32) {
        try await run(behindOtherCommands: true) { try await MailIMAPCommands.undeletedUIDs(folder: folder, imap: self.imap) }
    }

    func searchTexts(folder: String, uids: [UInt32], expectedUIDValidity: UInt32) async throws -> [UInt32: MailSearchText] {
        guard !uids.isEmpty else { return [:] }
        return try await run(behindOtherCommands: true) {
            try await MailIMAPCommands.searchTexts(folder: folder, uids: uids, expectedUIDValidity: expectedUIDValidity,
                                                   imap: self.imap) {
                try await self.letWaitingCommandsThroughAndReexamine(folder: folder, expectedUIDValidity: expectedUIDValidity)
            }
        }
    }

    private func letWaitingCommandsThroughAndReexamine(folder: String, expectedUIDValidity: UInt32) async throws {
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

    func storesFlagged(folder: String) async throws -> Bool {
        try await run { try await MailIMAPCommands.storesFlagged(folder: folder, imap: self.imap) }
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
    /// modified-UTF-7 name the caller passes is what reaches the wire, the same spelling
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

    @discardableResult
    private func run<T>(behindOtherCommands: Bool = false, _ body: () async throws -> T) async throws -> T {
        await commandLock.acquire(yielding: behindOtherCommands)
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

extension MailTransportScheme {
    nonisolated var swiftMailTransportSecurity: MailTransportSecurity {
        switch self {
        case .implicitTLS: .implicitTLS
        case .startTLS: .startTLS
        case .plaintext: .plainText
        }
    }
}

#endif