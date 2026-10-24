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
    static let shareHostName = String(shareHost.dropFirst("HTTPS://".count))
    private static let classTableType = "/CLASSTABLE/"
    static let prefix = shareHost + classTableType
    private static let tatAddress = tatPrefix.dropFirst("HTTPS://".count)

    /// Reads a code as scanned, typed or pasted; the forms it takes are in
    /// docs/decisions/0023-class-table-share-code.md.
    static func decode(_ text: String) throws -> ClassTableShareCode {
        // A pasted TAT link carries the spaces that pad a short student ID as `%20`.
        let code = (text.removingPercentEncoding ?? text).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // No code holds `?` or `#`, so what follows is a query or fragment someone added.
        let link = code.prefix { $0 != "?" && $0 != "#" }
        let scheme = ["HTTPS://", "HTTP://"].first { link.hasPrefix($0) }
        let address = link.dropFirst(scheme?.count ?? 0)
        if let path = shareHostPath(address) {
            if path.hasPrefix(classTableType) {
                return try decodePacked(prefix + withoutTrailingSlash(path.dropFirst(classTableType.count)))
            }
            throw namesType(path) ? ClassTableShareCodeError.unknownType : .malformed
        }
        if address.hasPrefix(tatAddress) {
            return try decodeTAT(tatPrefix + withoutTrailingSlash(address.dropFirst(tatAddress.count)))
        }
        // Off both hosts the code is the last segment, and anything short of a whole code is
        // not one, so a stray QR code or word never shows an error.
        let last = address.split(separator: "/").last ?? ""
        do {
            return try last.hasPrefix("TAT") ? decodeTAT(tatPrefix + last) : decodePacked(prefix + last)
        } catch {
            throw ClassTableShareCodeError.unknownPrefix
        }
    }

    private static func withoutTrailingSlash(_ text: Substring) -> Substring {
        text.last == "/" ? text.dropLast() : text
    }

    /// What follows the share host when the host ends there; nil for another host, including one
    /// that only starts the same.
    private static func shareHostPath(_ address: Substring) -> Substring? {
        guard address.hasPrefix(shareHostName) else { return nil }
        let rest = address.dropFirst(shareHostName.count)
        guard let next = rest.first else { return rest }
        return next == "/" ? rest : nil
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
