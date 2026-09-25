// FetchMessageInfoRequest.swift
// TigerDuck addition to the vendored copy — see VENDORED.md.

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

/// What `fetchMessageInfo(for:options:headerFields:)` and `fetchMessageInfosBulk(...)` actually
/// put on the wire for a given set of arguments.
///
/// A caller picks `FetchMessageInfoOptions` and header-field names; the `BODY.PEEK[...]` section
/// specifier those turn into is invisible to it, and the exact shape of that section decides
/// whether a non-conforming server's *response* can be parsed at all. A named header-field list
/// goes out as `BODY.PEEK[HEADER.FIELDS ("Name")]` with the field name quoted (RFC 3501's
/// `astring`); a server that echoes the section back with quoting of its own added produces
/// `BODY[HEADER.FIELDS (""NAME"")]`, which no IMAP parser can read — the whole FETCH response
/// then fails to decode and the fetch fails. `.fullHeader` (`BODY.PEEK[HEADER]`) has no list in
/// it and nothing to re-quote.
///
/// Callers that must stay inside what a fussy server can handle can pin their request shape
/// against this rather than against a comment.
public enum FetchMessageInfoRequest {
    /// The tagged `UID FETCH` command these arguments encode to, rendered exactly as it is sent.
    ///
    /// - Parameters:
    ///   - options: The attribute set, as passed to `fetchMessageInfo`.
    ///   - headerFields: Named header fields, as passed to `fetchMessageInfo`. Ignored by the
    ///     command itself when `options` already contains `.fullHeader`.
    ///   - uid: The UID to render the command for; only affects the identifier in the output.
    ///   - tag: The command tag to render.
    public static func wireCommand(
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil,
        uid: UInt32 = 1,
        tag: String = "A1"
    ) -> String {
        let command = FetchMessageInfoCommand<UID>(
            identifierSet: MessageIdentifierSet<UID>(UID(uid)),
            options: options,
            headerFields: headerFields
        )
        return String(reflecting: command.toTaggedCommand(tag: tag))
    }
}
