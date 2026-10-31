import Foundation

/// An NTUST term code: the ROC academic year, then `1`, `2` or `H` for summer. A year's terms run
/// 1, 2, H, so `114H` follows `1142` and precedes `1151`. NTUST pads years before 100, as in `99 1`.
public struct AcademicTerm: Hashable, Comparable, Sendable {
    public enum Season: Int, Comparable, CaseIterable, Sendable {
        case first = 1
        case second
        case summer

        public var letter: Character {
            switch self {
            case .first: "1"
            case .second: "2"
            case .summer: "H"
            }
        }

        /// Moodle spells summer `h`.
        public init?(letter: Character) {
            switch letter {
            case "1": self = .first
            case "2": self = .second
            case "H", "h": self = .summer
            default: return nil
            }
        }

        public static func < (lhs: Season, rhs: Season) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let year: Int
    public let season: Season

    public init(year: Int, season: Season) {
        self.year = year
        self.season = season
    }

    public init?(code: String) {
        guard let year = Self.year(of: code), let last = code.last, let season = Season(letter: last) else { return nil }
        self.init(year: year, season: season)
    }

    /// The year unpadded and summer upper-cased, as the course list and the app's caches write it.
    public var code: String { "\(year)\(season.letter)" }

    /// The regular term before this one; summer terms are optional, so a walk back skips them.
    public var previousRegular: AcademicTerm {
        switch season {
        case .first: AcademicTerm(year: year - 1, season: .second)
        case .second: AcademicTerm(year: year, season: .first)
        case .summer: AcademicTerm(year: year, season: .second)
        }
    }

    public var nextRegular: AcademicTerm {
        switch season {
        case .first: AcademicTerm(year: year, season: .second)
        case .second, .summer: AcademicTerm(year: year + 1, season: .first)
        }
    }

    public static func < (lhs: AcademicTerm, rhs: AcademicTerm) -> Bool {
        (lhs.year, lhs.season) < (rhs.year, rhs.season)
    }

    /// The year of any code that ends in one season character, read numerically so `99 1` is 99.
    public static func year(of code: String) -> Int? {
        Int(code.dropLast().trimmingCharacters(in: .whitespaces))
    }

    /// The ROC academic year, which starts on 1 August in Taipei.
    public static func academicYear(at date: Date) -> Int {
        let parts = TaipeiTime.calendar.dateComponents([.year, .month], from: date)
        let year = (parts.year ?? 0) - 1911
        return (parts.month ?? 0) >= 8 ? year : year - 1
    }

    /// The term the month suggests when no academic calendar says: February to July the second,
    /// August to January the first.
    public static func estimated(on date: Date) -> AcademicTerm {
        let month = TaipeiTime.calendar.component(.month, from: date)
        return AcademicTerm(year: academicYear(at: date), season: (2...7).contains(month) ? .second : .first)
    }

    /// `previousRegular` of a code. A summer code or one that is not a term comes back unchanged, which
    /// is how the cached-term walks have always treated them.
    public static func previousRegularCode(_ code: String) -> String {
        guard let term = AcademicTerm(code: code), term.season != .summer else { return code }
        return term.previousRegular.code
    }

    /// The upper-cased term a Moodle course id starts with: Moodle spells summer `h` and NTUST `H`.
    /// Any digit or letter after three digits counts, so every id with a term prefix splits alike.
    public static func codePrefix(ofMoodleId id: String) -> String? {
        guard id.count > 4 else { return nil }
        let prefix = id.prefix(4)
        guard prefix.dropLast().allSatisfy(\.isNumber),
              let season = prefix.last,
              season.isNumber || season.isLetter else { return nil }
        return prefix.uppercased()
    }

    /// A four-character code split for display: the year as written, padding kept, and the season.
    public static func displayParts(of code: String) -> (year: String, season: String)? {
        guard code.count == 4 else { return nil }
        return (String(code.prefix(3)), String(code.suffix(1)))
    }

    /// `114-1`; a code of another length as it is.
    public static func label(of code: String) -> String {
        guard let parts = displayParts(of: code) else { return code }
        return "\(parts.year)-\(parts.season)"
    }
}
