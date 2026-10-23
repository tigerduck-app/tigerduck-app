import Foundation

/// A class table share code: ours in the packed layout under `prefix`, or TAT's. See
/// docs/decisions/0023-class-table-share-code.md.
nonisolated struct ClassTableShareCode: Equatable, Sendable {
    enum Format: Equatable, Sendable {
        case tigerDuck
        /// TAT's code with class times, which the decoder checks and drops.
        case tat2
        /// TAT's older code, with no class times.
        case tat1
    }

    struct Term: Equatable, Sendable {
        let semester: String
        let courseNos: [String]
    }

    let format: Format
    let studentId: String?
    let sharedAt: Date?
    let terms: [Term]

    /// Every share link is `<TYPE>/<content>` on this host, in the upper case that keeps a QR
    /// code in alphanumeric mode, so a later version can share more than class tables.
    static let shareHost = "HTTPS://SHARE.TIGERDUCK.APP"
    static let prefix = shareHost + "/CLASSTABLE/"

    static func decode(_ text: String) throws -> ClassTableShareCode {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.hasPrefix(prefix) { return try decodePacked(code) }
        if let path = shareHostPath(code) {
            throw namesType(path) ? ClassTableShareCodeError.unknownType : .malformed
        }
        if code.hasPrefix(tatPrefix) { return try decodeTAT(code) }
        throw ClassTableShareCodeError.unknownPrefix
    }

    /// What follows the share host when the host ends there, as in a URL's path, query or
    /// fragment; nil for another host, including one that only starts the same.
    private static func shareHostPath(_ code: String) -> Substring? {
        guard code.hasPrefix(shareHost) else { return nil }
        let rest = code.dropFirst(shareHost.count)
        guard let next = rest.first else { return rest }
        return "/?#".contains(next) ? rest : nil
    }

    /// Whether `path` starts with a type a newer version writes: letters or digits, then `/`.
    private static func namesType(_ path: Substring) -> Bool {
        guard path.first == "/" else { return false }
        let afterSlash = path.dropFirst()
        guard let end = afterSlash.firstIndex(of: "/") else { return false }
        return isUpperAlphanumerics(afterSlash[..<end])
    }

    /// Our code for one of the user's terms, or every term that has courses. Course codes outside
    /// NTUST's shape are left out, and so is a term left without one; nil when nothing is left or
    /// the table is past the packed layout's limits.
    static func encode(studentId: String, sharedAt: Date, terms: [Term]) -> String? {
        let id = studentId.uppercased()
        guard isUpperAlphanumerics(id[...]) else { return nil }
        var semesters = Set<String>()
        let kept = terms.compactMap { term -> Term? in
            let semester = term.semester.uppercased()
            let courseNos = Set(term.courseNos.map { $0.uppercased() }.filter { CourseSelectionService.isCourseNo($0[...]) })
                .sorted()
            guard isSemester(semester[...]), !courseNos.isEmpty, semesters.insert(semester).inserted else {
                return nil
            }
            return Term(semester: semester, courseNos: courseNos)
        }
        guard !kept.isEmpty else { return nil }
        return encodePacked(studentId: id, sharedAt: sharedAt, terms: kept)
    }

    static func isSemester(_ text: Substring) -> Bool {
        text.utf8.count == 4 && isDigits(text.prefix(3)) && isUpperAlphanumerics(text.suffix(1))
    }

    static func checkedCourseNos(_ items: [Substring]) throws -> [String] {
        guard !items.contains(where: \.isEmpty), Set(items).count == items.count else {
            throw ClassTableShareCodeError.malformed
        }
        if let bad = items.first(where: { !CourseSelectionService.isCourseNo($0) }) {
            throw ClassTableShareCodeError.invalidCourseCode(String(bad))
        }
        return items.map(String.init)
    }

    static func isASCII(_ text: Substring) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 }
    }

    static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    static func isUpperAlphanumerics(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
        }
    }
}

nonisolated enum ClassTableShareCodeError: Error, Equatable, Sendable {
    /// Not a share code, such as another app's QR code.
    case unknownPrefix
    case unknownVersion
    /// Another type on the share host, which a newer version writes.
    case unknownType
    case malformed
    case checksumMismatch
    /// A TAT code's course code outside NTUST's shape; every course ours decodes to has that shape.
    case invalidCourseCode(String)
}
