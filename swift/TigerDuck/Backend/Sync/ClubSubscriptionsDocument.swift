import Foundation

/// The `club_subscriptions` settings document, which the iOS and Android apps write: for each club
/// whether it is subscribed and its color, each with the time it was set, and the order of the
/// subscribed clubs with its time, as in `{"clubs": {"93": {"subscribed": true, "subscribed_at":
/// "2026-11-02T14:00:00.000Z", "color": "#D35400", "color_at": "2026-11-02T14:00:00.000Z"}},
/// "order": {"ids": [93, 33], "at": "2026-11-02T14:05:00.000Z"}}`. A value another writer left
/// unreadable, or without its time, reads as absent.
nonisolated struct ClubSubscriptionsDocument: Equatable, Sendable {
    /// When a value was set: the text as written, which a write sends back unchanged, and its date.
    nonisolated struct Stamp: Equatable, Sendable {
        let text: String
        let date: Date

        init?(_ text: String) {
            guard let date = FullSyncRunner.backendDate(text) else { return nil }
            self.text = text
            self.date = date
        }

        /// `date` in the format of the app's other sync stamps, to the millisecond.
        init(_ date: Date) {
            text = TigerDuckDateFormatters.withFractional.string(from: date)
            self.date = FullSyncRunner.backendDate(text) ?? date
        }
    }

    nonisolated struct Stamped<Value: Equatable & Sendable>: Equatable, Sendable {
        var value: Value
        var at: Stamp
    }

    nonisolated struct Club: Equatable, Sendable {
        var subscribed: Stamped<Bool>?
        var color: Stamped<UInt32>?
    }

    var clubs: [Int: Club] = [:]
    var order: Stamped<[Int]>?

    /// The subscribed clubs, highest priority first: the user's order, then the clubs it lacks by
    /// the time they were subscribed, then by id.
    var subscribedIDs: [Int] {
        let since = clubs.compactMapValues { $0.subscribed?.value == true ? $0.subscribed?.at.date : nil }
        var listed = Set<Int>()
        let ordered = (order?.value ?? []).filter { since[$0] != nil && listed.insert($0).inserted }
        let rest = since.filter { !listed.contains($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
        return ordered + rest.map(\.key)
    }

    func isSubscribed(_ id: Int) -> Bool {
        clubs[id]?.subscribed?.value == true
    }

    /// The stamp of an edit made at `now`: `now`, or 1 ms after the latest stamp the document
    /// holds when that is later, so that a value another device stamped ahead by a wrong clock
    /// cannot outlast the edits made after it.
    func stamp(at now: Date) -> Stamp {
        let dates = clubs.values.flatMap { [$0.subscribed?.at.date, $0.color?.at.date] } + [order?.at.date]
        guard let latest = dates.compactMap({ $0 }).max() else { return Stamp(now) }
        return Stamp(max(now, latest.addingTimeInterval(0.001)))
    }

    /// Every value takes the side that set it later; a tie keeps the server's.
    static func merged(local: Self, server: Self) -> Self {
        var clubs = server.clubs
        for (id, mine) in local.clubs {
            let theirs = server.clubs[id]
            clubs[id] = Club(subscribed: later(mine.subscribed, theirs?.subscribed), color: later(mine.color, theirs?.color))
        }
        return Self(clubs: clubs, order: later(local.order, server.order))
    }

    private static func later<Value>(_ local: Stamped<Value>?, _ server: Stamped<Value>?) -> Stamped<Value>? {
        guard let local, let server else { return local ?? server }
        return local.at.date > server.at.date ? local : server
    }

    /// Puts the club last. It keeps the color it had; one never given a color gets `defaultColor`,
    /// stamped so that the default reaches the server too.
    mutating func subscribe(_ id: Int, defaultColor: UInt32, at stamp: Stamp) {
        guard !isSubscribed(id) else { return }
        var club = clubs[id] ?? Club()
        club.subscribed = Stamped(value: true, at: stamp)
        if club.color == nil { club.color = Stamped(value: defaultColor, at: stamp) }
        clubs[id] = club
        order = Stamped(value: subscribedIDs.filter { $0 != id } + [id], at: stamp)
    }

    /// Keeps the club's color for a later subscription.
    mutating func unsubscribe(_ id: Int, at stamp: Stamp) {
        guard isSubscribed(id) else { return }
        clubs[id]?.subscribed = Stamped(value: false, at: stamp)
    }

    /// `ids` is the subscribed clubs in their new order; ids of other clubs are left out.
    mutating func reorder(_ ids: [Int], at stamp: Stamp) {
        var listed = Set<Int>()
        let kept = ids.filter { isSubscribed($0) && listed.insert($0).inserted }
        guard kept != subscribedIDs else { return }
        order = Stamped(value: kept, at: stamp)
    }

    /// `color` is `0xRRGGBB`; higher bits are dropped, as `#RRGGBB` cannot carry them.
    mutating func setColor(_ color: UInt32, of id: Int, at stamp: Stamp) {
        let color = color & 0xFF_FFFF
        guard clubs[id]?.color?.value != color else { return }
        clubs[id, default: Club()].color = Stamped(value: color, at: stamp)
    }
}

// The wire form: `JSONDecoder` reads a Bool only from `true` or `false`, where `JSONSerialization`
// would take 1 for true.
nonisolated extension ClubSubscriptionsDocument {
    init(json: Data) {
        let wire = (try? JSONDecoder().decode(Wire.self, from: json)) ?? Wire()
        for (key, club) in wire.clubs ?? [:] {
            guard let id = Int(key), String(id) == key else { continue }
            var read = Club()
            if let value = club.subscribed, let at = club.subscribedAt.flatMap(Stamp.init) {
                read.subscribed = Stamped(value: value, at: at)
            }
            if let value = club.color.flatMap(Self.color(hex:)), let at = club.colorAt.flatMap(Stamp.init) {
                read.color = Stamped(value: value, at: at)
            }
            if read != Club() { clubs[id] = read }
        }
        if let ids = wire.order?.ids, let at = wire.order?.at.flatMap(Stamp.init) {
            order = Stamped(value: ids, at: at)
        }
    }

    func json() -> Data {
        let wire = Wire(
            clubs: Dictionary(uniqueKeysWithValues: clubs.map { id, club in
                (String(id), WireClub(
                    subscribed: club.subscribed?.value, subscribedAt: club.subscribed?.at.text,
                    color: club.color.map { String(format: "#%06X", $0.value) }, colorAt: club.color?.at.text
                ))
            }),
            order: order.map { WireOrder(ids: $0.value, at: $0.at.text) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(wire)) ?? Data("{}".utf8)
    }

    /// `#RRGGBB`, as course colors travel.
    static func color(hex: String) -> UInt32? {
        guard hex.count == 7, hex.first == "#", hex.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }

    private struct Wire: Codable {
        var clubs: [String: WireClub]?
        var order: WireOrder?

        init(clubs: [String: WireClub]? = nil, order: WireOrder? = nil) {
            self.clubs = clubs
            self.order = order
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            clubs = try? container?.decodeIfPresent([String: WireClub].self, forKey: .clubs)
            order = try? container?.decodeIfPresent(WireOrder.self, forKey: .order)
        }
    }

    private struct WireClub: Codable {
        var subscribed: Bool?
        var subscribedAt: String?
        var color: String?
        var colorAt: String?

        enum CodingKeys: String, CodingKey {
            case subscribed, color
            case subscribedAt = "subscribed_at", colorAt = "color_at"
        }

        init(subscribed: Bool?, subscribedAt: String?, color: String?, colorAt: String?) {
            self.subscribed = subscribed
            self.subscribedAt = subscribedAt
            self.color = color
            self.colorAt = colorAt
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            subscribed = try? container?.decodeIfPresent(Bool.self, forKey: .subscribed)
            subscribedAt = try? container?.decodeIfPresent(String.self, forKey: .subscribedAt)
            color = try? container?.decodeIfPresent(String.self, forKey: .color)
            colorAt = try? container?.decodeIfPresent(String.self, forKey: .colorAt)
        }
    }

    private struct WireOrder: Codable {
        var ids: [Int]?
        var at: String?

        enum CodingKeys: String, CodingKey {
            case ids, at
        }

        init(ids: [Int]?, at: String?) {
            self.ids = ids
            self.at = at
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            ids = container.flatMap { wholeNumberList(in: $0, forKey: .ids) }
            at = try? container?.decodeIfPresent(String.self, forKey: .at)
        }
    }
}
