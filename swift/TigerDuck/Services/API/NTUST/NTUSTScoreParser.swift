import Foundation
import SwiftSoup

/// Parses the NTUST StuScoreQueryServ DisplayAll HTML into a ``ScoreReport``.
///
/// Swift port of `backend/api/ntust/html_score_parser.py`. Layout selectors
/// and regex patterns are kept 1:1 with the Python reference so both stay
/// drop-in replacements for each other — any schema drift fixed in one side
/// must be mirrored in the other.
///
/// `nonisolated` so the parse can run off the main actor: under the
/// module's MainActor default isolation a multi-year transcript was being
/// parsed on the UI thread, which is what stuttered the score page on
/// older phones during a refresh.
nonisolated enum NTUSTScoreParser {

    // MARK: - Credit pattern registry
    //
    // Order matters — `^(\d+)$` matches everything else so it must run last.
    private static let creditPatterns: [(Regex<AnyRegexOutput>, CreditType)] = {
        let raw: [(String, CreditType)] = [
            (#"^\[\s*(\d+)\s*\]$"#, .educationProgram),   // [3]
            (#"^<\s*(\d+)\s*>$"#,   .notCounted),         // <3>
            (#"^#\s*(\d+)\s*$"#,    .notRequired),        // #3
            (#"^\(\s*(\d+)\s*\)$"#, .notEarned),          // (3) 不及格
            (#"^(\d+)$"#,           .normal),             // 3
        ]
        return raw.compactMap { pattern, type in
            guard let regex = try? Regex(pattern) else { return nil }
            return (regex, type)
        }
    }()

    private static let currentTermRegex: Regex<AnyRegexOutput>? = {
        try? Regex(#"期末評量時間\s*(\d{4})"#)
    }()

    // MARK: - Public API

    /// Parse raw HTML into a `ScoreReport`. Never throws — on failure returns
    /// `.empty`; individual sections gracefully degrade to empty arrays. The
    /// caller is expected to distinguish "parsed but empty" from "truly no
    /// content" via higher-level heuristics (e.g. also checking whether the
    /// session redirected to SSO).
    static func parse(html: String) -> ScoreReport {
        guard let doc = try? SwiftSoup.parse(html) else {
            return .empty
        }
        return ScoreReport(
            student: parseStudent(doc),
            currentTerm: parseCurrentTerm(doc),
            rankings: parseRankings(doc),
            courses: parseCourses(doc),
            creditSummary: parseCreditSummary(doc)
        )
    }

    // MARK: - Section parsers

    private static func parseStudent(_ doc: Document) -> String {
        // Localized navigation links the navbar may render across language
        // toggles. Add new entries here when NTUST adds a UI language.
        let excluded: Set<String> = [
            "登出", "登出系統",
            "Logout", "Log out", "Sign out",
            "English", "中文", "繁體中文", "簡體中文", "繁體", "簡體",
        ]
        let links: [Element] = (try? doc.select("ul.navbar-right a.nav-link").array()) ?? []
        for link in links {
            let name = cleanText(link)
            if !name.isEmpty && !excluded.contains(name) {
                return name
            }
        }
        return ""
    }

    private static func parseCurrentTerm(_ doc: Document) -> String {
        guard let regex = currentTermRegex else { return "" }
        let alerts: [Element] = (try? doc.select("div.alert-info").array()) ?? []
        for alert in alerts {
            let text = cleanText(alert)
            if let match = try? regex.firstMatch(in: text),
               match.count >= 2,
               let sub = match[1].substring {
                return String(sub)
            }
        }
        return ""
    }

    private static func parseRankings(_ doc: Document) -> [SemesterRanking] {
        guard let box = findBox(doc, byTitle: "排名資料"),
              let table = try? box.select("table").first() else {
            return []
        }
        let rows = rowsOf(table)
        guard rows.count > 1 else { return [] }

        return rows.dropFirst().compactMap { cells -> SemesterRanking? in
            guard cells.count >= 7 else { return nil }
            return SemesterRanking(
                term: cleanText(cells[0]),
                semester: RankingStats(
                    classRank: toInt(cleanText(cells[1])),
                    deptRank: toInt(cleanText(cells[2])),
                    gpa: toDouble(cleanText(cells[3]))
                ),
                cumulative: RankingStats(
                    classRank: toInt(cleanText(cells[4])),
                    deptRank: toInt(cleanText(cells[5])),
                    gpa: toDouble(cleanText(cells[6]))
                )
            )
        }
    }

    private static func parseCourses(_ doc: Document) -> [CourseGrade] {
        guard let box = findBox(doc, byTitle: "歷年學業成績列表"),
              let table = try? box.select("table").first() else {
            return []
        }
        let rows = rowsOf(table)
        guard rows.count > 1 else { return [] }

        return rows.dropFirst().compactMap { cells -> CourseGrade? in
            guard cells.count >= 9 else { return nil }

            let creditsRaw = cleanText(cells[4])
            let (credits, creditType) = parseCredits(creditsRaw)

            let grade = cleanText(cells[5])
            let remark = cleanText(cells[6])
            let status = classifyStatus(grade: grade, remark: remark)

            let geDimRaw = cleanText(cells[7])
            let geDim: String? = geDimRaw.isEmpty ? nil : geDimRaw

            let distanceRaw = cleanText(cells[8])
            let distanceLearning = !distanceRaw.isEmpty &&
                distanceRaw != "否" && distanceRaw != "N"

            return CourseGrade(
                index: toInt(cleanText(cells[0])),
                term: cleanText(cells[1]),
                code: cleanText(cells[2]),
                name: cleanText(cells[3]),
                credits: credits,
                creditType: creditType,
                grade: grade,
                status: status,
                remark: remark,
                geDimension: geDim,
                distanceLearning: distanceLearning
            )
        }
    }

    private static func parseCreditSummary(_ doc: Document) -> CreditSummary {
        guard let info = try? doc.select("#DataTables_Table_0_info table").first() else {
            return .empty
        }
        let rows = rowsOf(info)
        guard rows.count > 1 else { return .empty }

        // Label → key mapping mirrors Python `label_to_key`
        var earned = CreditBreakdown.zero
        var enrolled = CreditBreakdown.zero
        var total = CreditBreakdown.zero

        for cells in rows.dropFirst() {
            guard cells.count >= 4 else { continue }
            let label = cleanText(cells[0])
            let breakdown = CreditBreakdown(
                inPerson: toInt(cleanText(cells[1])) ?? 0,
                distance: toInt(cleanText(cells[2])) ?? 0,
                total: toInt(cleanText(cells[3])) ?? 0
            )
            switch label {
            case "已實得學分數": earned = breakdown
            case "修習中學分數": enrolled = breakdown
            case "合計":        total = breakdown
            default: continue
            }
        }
        return CreditSummary(earned: earned, enrolled: enrolled, total: total)
    }

    // MARK: - Shared helpers

    /// Text of an element with whitespace collapsed; mirrors Python `_text`.
    private static func cleanText(_ element: Element) -> String {
        let raw = (try? element.text()) ?? ""
        return raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func toInt(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespaces))
    }

    private static func toDouble(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespaces))
    }

    private static func parseCredits(_ raw: String) -> (credits: Int?, type: CreditType) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for (regex, type) in creditPatterns {
            guard let match = try? regex.firstMatch(in: trimmed),
                  match.count >= 2,
                  let sub = match[1].substring,
                  let value = Int(sub) else {
                continue
            }
            return (value, type)
        }
        return (nil, .unknown)
    }

    private static func classifyStatus(grade: String, remark: String) -> GradeStatus {
        let g = grade.trimmingCharacters(in: .whitespaces)
        let r = remark.trimmingCharacters(in: .whitespaces)

        if g.contains("二次退選") || r.contains("二次退選") { return .withdrew }
        if r.contains("抵免") { return .exempted }
        if g.contains("成績未到") { return .pending }
        if g == "通過" || g == "不通過" { return .passed }
        if g.isEmpty { return .unknown }
        return .graded
    }

    /// Locate the `<div class="box">` whose `.box-header h2` contains the
    /// given title. More tolerant to layout reshuffles than hard-coded
    /// positional indexing.
    private static func findBox(_ doc: Document, byTitle title: String) -> Element? {
        let boxes: [Element] = (try? doc.select("div.box").array()) ?? []
        for box in boxes {
            guard let header = try? box.select(".box-header h2").first() else { continue }
            if cleanText(header).contains(title) {
                return box
            }
        }
        return nil
    }

    /// Flatten a `<table>` into rows of cell elements, dropping empty rows.
    /// Mirrors Python `_rows_of`.
    private static func rowsOf(_ table: Element) -> [[Element]] {
        let trs: [Element] = (try? table.select("tr").array()) ?? []
        return trs.compactMap { tr in
            let cells: [Element] = (try? tr.select("td, th").array()) ?? []
            return cells.isEmpty ? nil : cells
        }
    }
}
