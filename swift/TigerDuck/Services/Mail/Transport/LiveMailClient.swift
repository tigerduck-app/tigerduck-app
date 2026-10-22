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

    nonisolated static func recoversByLocalParse(_ info: MessageInfo) -> Bool {
        guard info.bodyStructureUnusable else { return false }
        guard let size = info.size else { return true }
        return size <= MailConstants.maxLocalParseBytes
    }

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

    func createFolder(_ name: String) async throws {
        try await run { try await self.imap.createMailbox(name) }
    }

    func append(_ message: Data, to folder: String, flags: [MailFlag]) async throws {
        try await run {
            try await self.imap.append(rawMessage: String(decoding: message, as: UTF8.self), to: folder,
                                       flags: flags.map(\.swiftMailFlag), internalDate: nil)
        }
    }

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

    private func rawSearch(criteria: [SearchCriteria]) async throws -> MessageIdentifierSet<UID> {
        try await imap.search(criteria: criteria)
    }

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
            return classify(String(describing: sendError), fallback: .protocolError(String(describing: sendError)))
        }
        if isDecodeFailure(error) { return .protocolError(String(describing: error)) }
        let described = String(describing: error)
        return classify(described, fallback: isNetworkShaped(error) ? .unreachable : .protocolError(described))
    }

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

    nonisolated static func mapSearchError(_ error: IMAPError) -> MailClientError {
        switch error {
        case .commandFailed, .commandNotSupported: .searchUnsupported
        default: map(error)
        }
    }

    nonisolated static func classifyLoginFailure(_ text: String) -> MailClientError {
        let lowered = text.lowercased()
        let busyResponseCodes = ["[unavailable]", "[limit]", "[inuse]"]
        if busyResponseCodes.contains(where: lowered.contains) { return .serverBusy }
        if lowered.contains("too many connections") { return .serverBusy }
        return .authenticationFailed
    }

    nonisolated static func classify(_ text: String, fallback: MailClientError) -> MailClientError {
        let lowered = text.lowercased()
        if lowered.contains("certificate") { return .certificateRejected }
        if lowered.contains("too many") || lowered.contains("busy") || lowered.contains("try again later") { return .serverBusy }
        if lowered.contains("authenticationfailed") || lowered.contains("login failed") { return .authenticationFailed }
        return fallback
    }

    nonisolated static func summary(from info: MessageInfo) -> MailSummary? {
        guard let uid = info.uid?.value else { return nil }
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
