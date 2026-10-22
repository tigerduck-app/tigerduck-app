#if os(iOS)
import Foundation

nonisolated enum MailTextCleaner {
    private static let bidiControls: Set<UInt32> = Set<UInt32>(0x202A...0x202E)
        .union(0x2066...0x2069)
        .union([0x200E, 0x200F, 0x061C])

    private static let controls: Set<UInt32> = Set<UInt32>(0x0000...0x0008)
        .union([0x000B, 0x000C])
        .union(0x000E...0x001F)
        .union([0x007F])

    private static let asciiWhitespace: Set<UInt32> = [0x0020, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D]

    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if controls.contains(scalar.value) || bidiControls.contains(scalar.value) { continue }
            if asciiWhitespace.contains(scalar.value) {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func visibleText(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisible($0) }))
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x200B || scalar.value == 0x2800 { return true }
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.properties.generalCategory {
        case .format, .control: return true
        default: return false
        }
    }
}
#endif
