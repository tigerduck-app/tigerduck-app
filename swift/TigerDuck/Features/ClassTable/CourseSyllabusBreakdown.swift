import Foundation

/// The syllabus's shares drawn as a stacked bar: grading parsed from its text, and teaching
/// methods from the Instruction fields.
nonisolated enum CourseSyllabusBreakdown {
    struct Part: Hashable, Sendable {
        let label: String
        /// Nil for a row with no share in the bar, such as Others written without a percentage.
        let percent: Double?
        var detail: String?
    }

    static let maxLabelLength = 20
    /// Longer pieces are prose, and the lazy pattern would backtrack through all of it.
    static let maxPieceLength = 200

    /// Nil when one part is not a short label followed by a percentage, to show the text as written.
    static func grading(_ text: String) -> [Part]? {
        let pieces = text
            .split { $0.isNewline || ";；,，、".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let parts = pieces.compactMap(gradingPart)
        guard !parts.isEmpty, parts.count == pieces.count, parts.contains(where: { $0.percent ?? 0 > 0 }) else {
            return nil
        }
        return parts
    }

    /// The methods above 0%, then Others with its text; nil when there is neither.
    static func teaching(_ syllabus: CourseSyllabus) -> [Part]? {
        let methods = [
            (syllabus.Instruction_1, String(localized: "course_detail_syllabus_lecture")),
            (syllabus.Instruction_2, String(localized: "course_detail_syllabus_group_discussion")),
            (syllabus.Instruction_3, String(localized: "course_detail_syllabus_case_study")),
            (syllabus.Instruction_4, String(localized: "course_detail_syllabus_practical")),
        ]
        var parts = methods.compactMap { value, label in
            let percent = share(value)
            return percent > 0 ? Part(label: label, percent: percent) : nil
        }
        if let other = syllabus.Instruction_other?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
            let label = String(localized: "course_detail_syllabus_other")
            if case let (text, percent)? = trailingPercent(other) {
                parts.append(Part(label: label, percent: percent, detail: text.isEmpty ? nil : text))
            } else {
                parts.append(Part(label: label, percent: nil, detail: other))
            }
        }
        return parts.isEmpty ? nil : parts
    }

    /// An Instruction field's percentage: blank, non-numeric or negative counts as 0.
    static func share(_ value: String?) -> Double {
        var text = value?.trimmingCharacters(in: .whitespaces) ?? ""
        if text.hasSuffix("%") || text.hasSuffix("％") { text.removeLast() }
        guard let share = Double(text.trimmingCharacters(in: .whitespaces)), share.isFinite else { return 0 }
        return max(share, 0)
    }

    private static func gradingPart(_ piece: String) -> Part? {
        guard case let (text, percent)? = trailingPercent(piece) else { return nil }
        // Numbered lists ("1.", "(2)", "-") lead many syllabi's lines.
        let label = text
            .replacing(/^(?:[0-9]{1,2}[.)、]|[(（][0-9]{1,2}[)）]|[-•‧・*])\s*/, with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= maxLabelLength else { return nil }
        return Part(label: label, percent: percent)
    }

    /// The text before a closing percentage, without the separator between them.
    private static func trailingPercent(_ text: String) -> (String, Double)? {
        guard text.count <= maxPieceLength else { return nil }
        let pattern = /(.*?)[\s:：=－\-]*[(（]?([0-9]{1,3}(?:\.[0-9]+)?)\s*[%％][)）]?/
        guard let match = text.wholeMatch(of: pattern), let percent = Double(match.2) else { return nil }
        return (String(match.1).trimmingCharacters(in: .whitespaces), percent)
    }
}

/// The syllabus as its page shows it: each field trimmed, and nil when blank.
nonisolated extension CourseSyllabus {
    var grading: String? { Self.text(CourseGrading) }
    var outline: String? { Self.text(CourseObject) }
    var content: String? { Self.text(CourseContent) }
    var notes: String? { Self.text(CourseNote) }
    var objectives: String? { Self.text(CoreAbility) }

    var references: String? {
        let books = [CourseTextbook, CourseRefbook].compactMap(Self.text)
        return books.isEmpty ? nil : books.joined(separator: "\n\n")
    }

    var website: URL? {
        guard let text = Self.text(CourseURL), let url = URL(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var hasContent: Bool {
        [grading, outline, content, references, notes, objectives].contains { $0 != nil } || website != nil
            || CourseSyllabusBreakdown.teaching(self) != nil
    }

    private static func text(_ value: String?) -> String? {
        let text = value?.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
