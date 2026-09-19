#if os(iOS)
import Foundation

/// What the sent-copy dedupe probe actually established — three values, because the server can
/// also refuse to answer.
///
/// Mail2000's measured CAPABILITY banner is `IMAP4 IMAP4rev1 AUTH=LOGIN LITERAL+ ID NAMESPACE
/// STARTTLS` (design doc §1.2). Nothing in it promises that `SEARCH HEADER "Message-ID"` is
/// honoured, so "the probe failed" is a case this code has to be able to represent — not an edge
/// it can flatten into "not saved" and hope for. Flattening it is exactly what
/// `(try? await client.containsMessageID(…)) ?? false` did, which made a server that refuses
/// that search key duplicate every single sent mail.
nonisolated enum SentCopyProbe: Equatable, Sendable {
    /// The server has a message with this Message-ID in the folder: it filed its own copy.
    case found
    /// The server answered, and the copy is not there.
    case notFound
    /// The server refused or failed the search. Says nothing either way.
    case unknown
}

/// What became of the copy of a sent mail, reported rather than discarded. The mail itself has
/// already gone out by the time any of these is produced — none of them means a failed send.
nonisolated enum SentCopy: Equatable, Sendable {
    /// TigerDuck appended the copy to Sent.
    case filed
    /// The server had already filed its own copy, so nothing was appended.
    case serverFiledItself
    /// There is no Sent folder and none could be created, so nothing was tried.
    case notAttempted
    /// The APPEND itself failed.
    case failed(MailClientError)
    /// The dedupe probe could not be answered, so nothing was appended — see `SentCopyFiler.file`.
    case unknown
}

/// Files the copy of a mail that has just been sent (design doc §8.4), and reports what happened.
///
/// `nonisolated` and taking every dependency as a parameter, so it runs inside a
/// `MailPageSession.use` body without capturing a view model — and so a test can drive it
/// directly.
nonisolated enum SentCopyFiler {
    /// One attempt at filing a sent copy.
    struct Filing: Equatable, Sendable {
        var outcome: SentCopy
        /// The role map `MailFolderProvisioner` re-resolved from a fresh `LIST`, when there was a
        /// Sent folder to resolve. `nil` when there is none and none could be made.
        var roles: [MailFolderRole: String]?
        /// The server rejected the password during one of the steps below. Filing a copy is
        /// best-effort and must never fail the send, so the rejection cannot travel as a thrown
        /// error the way every other command's does — but §7.4 still has to hear about it, or the
        /// next tap sends a password the server has already refused. The caller reports it.
        var rejectedPassword = false
    }

    /// Ensures a Sent folder, asks whether the server filed its own copy, and appends one if it
    /// did not.
    ///
    /// **A probe that cannot be answered does not append.** This is deliberate, and it is the
    /// whole point of `SentCopyProbe.unknown` existing: a missing copy is quiet, recoverable (the
    /// mail really was sent, and the user is told so), and costs nothing to live with; a
    /// duplicate is clutter in someone's own mailbox that they have to find and delete by hand,
    /// on every single send, for as long as the server keeps refusing the search. If this ever
    /// looks like it should append on `.unknown` "to be safe", it is the duplicate that is unsafe.
    static func file(
        _ message: Data,
        messageID: String,
        in roles: [MailFolderRole: String],
        client: any MailClient,
        dedupeDelay: Duration,
        sleep: (Duration) async -> Void
    ) async -> Filing {
        // The mail has gone out, so there is now a copy worth filing — and only now may a missing
        // Sent folder be created for it. An account without one used to lose the copy silently.
        // If the CREATE fails the mail still went, which is the part worth protecting: sending is
        // the point, filing the copy is not worth failing it for.
        guard let sent = await MailFolderProvisioner.ensure(.sent, in: roles, client: client) else {
            return Filing(outcome: .notAttempted)
        }
        // Save a sent copy only if the server did not file one itself (§8.4). Still asked even
        // for a folder just created, because the server files its own copy on its own schedule
        // and may well have made the same folder first.
        await sleep(dedupeDelay)
        let probed = await probe(messageID, in: sent.name, client: client)
        switch probed.result {
        case .found:
            return Filing(outcome: .serverFiledItself, roles: sent.roles)
        case .unknown:
            return Filing(outcome: .unknown, roles: sent.roles,
                          rejectedPassword: probed.failure == .authenticationFailed)
        case .notFound:
            do {
                try await client.append(message, to: sent.name, flags: [.seen])
                return Filing(outcome: .filed, roles: sent.roles)
            } catch {
                let mapped = (error as? MailClientError) ?? .protocolError("sent copy append failed")
                return Filing(outcome: .failed(mapped), roles: sent.roles,
                              rejectedPassword: mapped == .authenticationFailed)
            }
        }
    }

    /// `client.containsMessageID`, keeping the distinction `(try? …) ?? false` threw away — and,
    /// alongside it, the failure behind an `.unknown`, which a bare three-valued answer cannot
    /// carry and which `Filing.rejectedPassword` needs.
    static func probe(
        _ messageID: String, in folder: String, client: any MailClient
    ) async -> (result: SentCopyProbe, failure: MailClientError?) {
        do {
            return (try await client.containsMessageID(messageID, in: folder) ? .found : .notFound, nil)
        } catch {
            return (.unknown, (error as? MailClientError) ?? .protocolError("sent copy probe failed"))
        }
    }
}
#endif
