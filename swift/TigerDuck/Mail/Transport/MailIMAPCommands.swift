#if os(iOS)
import Foundation
import SwiftMail

nonisolated enum MailIMAPCommands {
    static func status(folder: String, imap: IMAPServer) async throws -> MailboxStatusInfo {
        // EXAMINE, not STATUS: `IMAPServer.mailboxStatus` asks STATUS for UIDNEXT and
        // UIDVALIDITY only when the server advertises UIDPLUS, which Mail2000 does not, and
        // EXAMINE's response always carries both.
        let selection = try await imap.examineMailbox(folder)
        return MailboxStatusInfo(uidValidity: selection.uidValidity.value, uidNext: selection.uidNext.value)
    }

    static func page(folder: String, olderThanSequence: Int?, pageSize: Int, imap: IMAPServer) async throws -> MailFolderPage {
        let selection = try await imap.examineMailbox(folder)
        let total = selection.messageCount
        let upper = min((olderThanSequence ?? total + 1) - 1, total)
        guard upper >= 1 else {
            return MailFolderPage(folder: folder, uidValidity: selection.uidValidity.value,
                                  messageCount: total, summaries: [], oldestLoadedSequence: nil,
                                  uidNext: selection.uidNext.value)
        }
        let lower = max(1, upper - pageSize + 1)
        let infos = try await imap.fetchMessageInfos(
            sequenceRange: SequenceNumber(lower)...SequenceNumber(upper),
            options: LiveMailClient.summaryOptions
        )
        let summaries = infos.compactMap(MailIMAPMessages.summary(from:)).filter { !$0.isDeleted }.sorted { $0.uid > $1.uid }
        return MailFolderPage(folder: folder, uidValidity: selection.uidValidity.value, messageCount: total,
                              summaries: summaries, oldestLoadedSequence: lower > 1 ? lower : nil,
                              uidNext: selection.uidNext.value,
                              windowUIDs: MailFolderPage.span(of: infos.compactMap { $0.uid?.value }))
    }

    static func summaries(folder: String, fromUID: UInt32, imap: IMAPServer) async throws -> [MailSummary] {
        _ = try await imap.examineMailbox(folder)
        let infos = try await imap.fetchMessageInfos(
            uidRange: UID(fromUID)..., options: [.envelope, .internalDate, .flags, .size]
        )
        return infos.compactMap(MailIMAPMessages.summary(from:))
    }

    static func summaries(folder: String, uids: [UInt32], expectedUIDValidity: UInt32?, imap: IMAPServer) async throws -> [MailSummary] {
        try await examine(folder, expecting: expectedUIDValidity, imap: imap)
        let infos = try await imap.fetchMessageInfosBulk(using: MailIMAPFetch.uidSet(uids), options: LiveMailClient.summaryOptions)
        return infos.compactMap(MailIMAPMessages.summary(from:))
    }

    static func flags(
        folder: String, uids: ClosedRange<UInt32>, expectedUIDValidity: UInt32?, imap: IMAPServer
    ) async throws -> [UInt32: MailFlags] {
        try await examine(folder, expecting: expectedUIDValidity, imap: imap)
        let infos = try await imap.fetchMessageInfos(uidRange: UID(uids.lowerBound)...UID(uids.upperBound), options: [.flags])
        var result: [UInt32: MailFlags] = [:]
        for info in infos {
            guard let uid = info.uid?.value else { continue }
            result[uid] = MailFlags(seen: info.flags.contains(.seen),
                                    answered: info.flags.contains(.answered),
                                    deleted: info.flags.contains(.deleted))
        }
        return result
    }

    static func undeletedUIDs(folder: String, imap: IMAPServer) async throws -> (uids: [UInt32], uidValidity: UInt32) {
        let selection = try await imap.examineMailbox(folder)
        let found = try await rawSearch(criteria: [.undeleted], imap: imap)
        return (found.toArray().map(\.value), selection.uidValidity.value)
    }

    static func searchTexts(
        folder: String, uids: [UInt32], expectedUIDValidity: UInt32, imap: IMAPServer,
        stepAside: () async throws -> Void
    ) async throws -> [UInt32: MailSearchText] {
        try await examine(folder, expecting: expectedUIDValidity, imap: imap)
        let infos = try await imap.fetchMessageInfosBulk(using: MailIMAPFetch.uidSet(uids), options: LiveMailClient.summaryOptions)
        var texts: [UInt32: MailSearchText] = [:]
        for info in infos {
            guard let summary = MailIMAPMessages.summary(from: info), !summary.isDeleted else { continue }
            try await stepAside()
            let body = try await MailIMAPFetch.searchBody(of: info, folder: folder, expectedUIDValidity: expectedUIDValidity,
                                                          imap: imap)
            texts[summary.uid] = MailSearchText(of: summary, body: body)
        }
        return texts
    }

    static func setFlag(
        _ flag: MailFlag, on: Bool, folder: String, uids: [UInt32], expectedUIDValidity: UInt32?, imap: IMAPServer
    ) async throws {
        try await select(folder, expecting: expectedUIDValidity, imap: imap)
        try await imap.store(flags: [flag.swiftMailFlag], on: MailIMAPFetch.uidSet(uids), operation: on ? .add : .remove)
    }

    /// SELECT, as a read-only EXAMINE lists no permanent flags (RFC 3501 §6.3.2).
    static func storesFlagged(folder: String, imap: IMAPServer) async throws -> Bool {
        storesFlagged(permanentFlags: try await imap.selectMailbox(folder).permanentFlags)
    }

    /// SwiftMail reports PERMANENTFLAGS' `\*` (RFC 3501 §7.1) as `.custom("wildcard")`.
    static func storesFlagged(permanentFlags: [Flag]) -> Bool {
        permanentFlags.contains(.flagged) || permanentFlags.contains(.custom("wildcard"))
    }

    static func copy(folder: String, uids: [UInt32], to target: String, expectedUIDValidity: UInt32, imap: IMAPServer) async throws {
        try await select(folder, expecting: expectedUIDValidity, imap: imap)
        try await imap.copy(messages: MailIMAPFetch.uidSet(uids), to: target)
    }

    static func deletedUIDs(folder: String, expectedUIDValidity: UInt32, imap: IMAPServer) async throws -> Set<UInt32> {
        try await examine(folder, expecting: expectedUIDValidity, imap: imap)
        let found = try await rawSearch(criteria: [.deleted], imap: imap)
        return Set(found.toArray().map(\.value))
    }

    static func expunge(folder: String, expectedUIDValidity: UInt32, imap: IMAPServer) async throws {
        try await select(folder, expecting: expectedUIDValidity, imap: imap)
        try await imap.expunge()
    }

    static func append(_ message: Data, to folder: String, flags: [MailFlag], imap: IMAPServer) async throws {
        // SwiftMail's IMAP `append` has no `Data` overload (IMAPServer+Append.swift).
        try await imap.append(rawMessage: String(decoding: message, as: UTF8.self), to: folder,
                              flags: flags.map(\.swiftMailFlag), internalDate: nil)
    }

    static func containsMessageID(_ messageID: String, in folder: String, imap: IMAPServer) async throws -> Bool {
        _ = try await imap.examineMailbox(folder)
        let found = try await rawSearch(criteria: [.header("Message-ID", messageID)], imap: imap)
        return !found.isEmpty
    }

    static func examine(_ folder: String, expecting expectedUIDValidity: UInt32?, imap: IMAPServer) async throws {
        let selection = try await imap.examineMailbox(folder)
        try MailIMAPFetch.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
    }

    private static func select(_ folder: String, expecting expectedUIDValidity: UInt32?, imap: IMAPServer) async throws {
        let selection = try await imap.selectMailbox(folder)
        try MailIMAPFetch.assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
    }

    private static func rawSearch(criteria: [SearchCriteria], imap: IMAPServer) async throws -> MessageIdentifierSet<UID> {
        do {
            return try await imap.search(criteria: criteria)
        } catch let error as IMAPError {
            throw MailIMAPErrors.mapSearchError(error)
        }
    }
}

nonisolated enum MailSMTP {
    static func send(
        _ message: Data, from sender: String, to recipients: [String], studentID: String, password: String,
        config: MailServerConfig
    ) async throws {
        let smtp = SMTPServer(
            host: config.smtpHost,
            port: config.smtpPort,
            transportSecurity: config.smtpScheme.swiftMailTransportSecurity,
            certificateVerificationPolicy: .custom(MailTLSVerifier.swiftMailVerifier),
            minimumTLSVersion: .tlsv12
        )
        do {
            try await smtp.connect()
            try await smtp.login(username: studentID, password: password)
            try await smtp.sendRawMessage(message, from: EmailAddress(address: sender),
                                          to: recipients.map { EmailAddress(address: $0) })
            try? await smtp.disconnect()
        } catch {
            try? await smtp.disconnect()
            throw MailIMAPErrors.map(error)
        }
    }
}

private extension MailFlag {
    nonisolated var swiftMailFlag: SwiftMail.Flag {
        switch self {
        case .seen: .seen
        case .answered: .answered
        case .flagged: .flagged
        case .deleted: .deleted
        case .draft: .draft
        }
    }
}
#endif
