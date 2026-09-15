#if os(iOS)
import Foundation

/// Appendix A.3: sender names, subjects, attachment names and notification text lose
/// every Unicode bidi control, which defeats invoice-then-hidden-RTL-override-style disguises.
nonisolated enum MailTextCleaner {
    private static let bidiControls: Set<UInt32> = Set<UInt32>(0x202A...0x202E)
        .union(0x2066...0x2069)
        .union([0x200E, 0x200F, 0x061C])

    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !bidiControls.contains($0.value) })
        return String(scalars)
    }
}
#endif
