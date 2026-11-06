import Foundation
import TigerDuckCore

/// A club of the public directory, https://clubs.ntust.edu.tw/api/v1/public/clubs, with the fields
/// the app shows.
nonisolated struct ClubCard: Decodable, Equatable, Sendable, Identifiable {
    let id: Int
    let name: String
    let enName: String?
    /// One of `ClubDirectory.attributeOrder`; any other value, or none, is unclassified.
    let attribute: String?
    /// Written in Chinese only.
    let tagline: String?

    enum CodingKeys: String, CodingKey {
        case id, name, attribute, tagline
        case enName = "en_name"
    }

    /// The Chinese name in a Chinese interface; elsewhere the English one when the club has one.
    func displayName(chinese: Bool) -> String {
        guard !chinese, let enName, !enName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return name }
        return enName
    }
}

nonisolated enum ClubActivityKind: Decodable, Equatable, Sendable {
    case meeting
    case event
    /// A kind this build does not know, as the feed names it.
    case other(String)

    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "社課或會議": self = .meeting
        case "活動": self = .event
        case let other: self = .other(other)
        }
    }
}

/// An activity of the school-wide feed, https://clubs.ntust.edu.tw/api/v1/public/activities. Its
/// dates and times are Taipei wall-clock values.
nonisolated struct ClubActivity: Decodable, Equatable, Sendable, Identifiable {
    let id: Int
    let name: String
    let clubID: Int
    /// The club's Chinese name.
    let clubName: String
    /// `yyyy-MM-dd`.
    let date: String?
    let endDate: String?
    /// `HH:mm:ss`.
    let startTime: String?
    let endTime: String?
    let location: String
    let kind: ClubActivityKind
    let content: String

    enum CodingKeys: String, CodingKey {
        case id, name, date, location, content
        case clubID = "club_id", clubName = "club_name", endDate = "end_date"
        case startTime = "start_time", endTime = "end_time", kind = "type"
    }

    /// The day and the minutes after midnight of an activity that starts and ends on one day; nil
    /// for one that spans days, lacks a time or does not end after it starts.
    var oneDay: (day: String, start: Int, end: Int)? {
        guard let date, date == endDate, let start = Self.minutes(startTime), let end = Self.minutes(endTime), start < end
        else { return nil }
        return (date, start, end)
    }

    private static func minutes(_ time: String?) -> Int? {
        let parts = time?.split(separator: ":", omittingEmptySubsequences: false) ?? []
        guard parts.count == 3, parts[1].count == 2, parts[2].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]), let second = Int(parts[2]),
              (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second) else { return nil }
        return ClassTimeline.minutes(of: "\(parts[0]):\(parts[1])")
    }
}

/// The `data` list of the API's envelope, `{success, data, error, meta}`, less the elements this
/// build cannot read, so that one bad row does not hide the others, and less a second row of an
/// id. A list none of whose rows reads is unreadable as a whole.
nonisolated struct ClubAPIList<Element: Decodable & Sendable & Identifiable>: Decodable, Sendable {
    let elements: [Element]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decode([Lenient<Element>].self, forKey: .data)
        var seen = Set<Element.ID>()
        elements = rows.compactMap(\.value).filter { seen.insert($0.id).inserted }
        guard rows.isEmpty || !elements.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "no row is readable")
        }
    }

    static func decode(_ body: Data) throws -> [Element] {
        try JSONDecoder().decode(Self.self, from: body).elements
    }
}
