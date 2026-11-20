#if os(iOS)
import Foundation

nonisolated enum ASCIIText {
    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard scalar.value >= 0x41, scalar.value <= 0x5A, let lowered = Unicode.Scalar(scalar.value + 0x20) else {
            return scalar
        }
        return lowered
    }

    /// Not `String.hasPrefix`, which compares `Character`s (extended grapheme clusters): a
    /// combining mark attaches to whatever scalar precedes it, including `/` or another scheme
    /// letter, merging it into one `Character` that no longer equals the plain ASCII character
    /// `hasPrefix` is looking for.
    static func hasASCIICaseInsensitivePrefix(_ text: String, _ prefix: String) -> Bool {
        var iterator = text.unicodeScalars.makeIterator()
        for expected in prefix.unicodeScalars {
            guard let next = iterator.next(), asciiLowercased(next) == asciiLowercased(expected) else { return false }
        }
        return true
    }

    static func isASCIICaseInsensitiveEqual(_ text: some StringProtocol, _ other: String) -> Bool {
        let textScalars = Array(text.unicodeScalars)
        let otherScalars = Array(other.unicodeScalars)
        guard textScalars.count == otherScalars.count else { return false }
        return zip(textScalars, otherScalars).allSatisfy { asciiLowercased($0) == asciiLowercased($1) }
    }
}
#endif
