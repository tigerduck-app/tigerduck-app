import Foundation
import SwiftCross

/// Resolves a MIME charset label to a `String.Encoding` when decoding RFC 2047 encoded
/// words and charset-tagged content.
///
/// The default is the IANA registry. A client with locale-specific policy — for example
/// decoding `big5` as its HKSCS superset — installs its own resolver once at startup.
/// Returning `nil` from a custom resolver falls back to the IANA lookup.
public enum MailCharsetResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var custom: (@Sendable (String) -> String.Encoding?)?

    public static func setResolver(_ resolver: (@Sendable (String) -> String.Encoding?)?) {
        lock.withLock { custom = resolver }
    }

    public static func resolve(_ label: String) -> String.Encoding? {
        let resolver = lock.withLock { custom }
        return resolver?(label) ?? String.Encoding(ianaCharsetName: label)
    }
}
