#if os(iOS)
import Foundation

/// What the sent-copy dedupe probe established. Three values, because the server can also
/// refuse to answer.
///
/// Mail2000's measured CAPABILITY banner is `IMAP4 IMAP4rev1 AUTH=LOGIN LITERAL+ ID NAMESPACE
/// STARTTLS`, and nothing in it promises that `SEARCH HEADER "Message-ID"` is honoured, so
/// "the probe failed" needs its own case. Flattening it into "not saved", as
/// `(try? await client.containsMessageID(…)) ?? false` would, makes a server that refuses that
/// search key duplicate every sent mail.
nonisolated enum SentCopyProbe: Equatable, Sendable {
    case found
    case notFound
    case unknown
}

nonisolated enum SentCopy: Equatable, Sendable {
    case filed
    case serverFiledItself
    case notAttempted
    case failed(MailClientError)
    case unknown
}

nonisolated enum SentCopyFiler {
    struct Filing: Equatable, Sendable {
        var outcome: SentCopy
        var roles: [MailFolderRole: String]?
        var rejectedPassword = false
    }

    static func file(
        _ message: Data,
        messageID: String,
        in roles: [MailFolderRole: String],
        client: any MailClient,
        dedupeDelay: Duration,
        sleep: (Duration) async -> Void
    ) async -> Filing {
        guard let sent = await MailFolderProvisioner.ensure(.sent, in: roles, client: client) else {
            return Filing(outcome: .notAttempted)
        }
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
