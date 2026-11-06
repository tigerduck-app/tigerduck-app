import Foundation

public struct AccentGradient: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        case linear, radial, angular, mesh
    }

    /// The screen's own sides, which no layout direction mirrors, in 45-degree steps clockwise.
    public enum Direction: String, Codable, CaseIterable, Sendable {
        case leftToRight, topLeftToBottomRight, topToBottom, topRightToBottomLeft
        case rightToLeft, bottomRightToTopLeft, bottomToTop, bottomLeftToTopRight
    }

    public static let stopCounts = 1...5

    /// A change that leaves no stop or more than five is undone.
    public var stops: [Int] {
        didSet { stops = Self.stopCounts.contains(stops.count) ? stops.map(Self.rgb) : oldValue }
    }
    public var style: Style
    public var direction: Direction

    public init(color: Int) {
        stops = [Self.rgb(color)]
        style = .linear
        direction = .topLeftToBottomRight
    }

    public init?(stops: [Int], style: Style = .linear, direction: Direction = .topLeftToBottomRight) {
        guard Self.stopCounts.contains(stops.count) else { return nil }
        self.stops = stops.map(Self.rgb)
        self.style = style
        self.direction = direction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let accent = AccentGradient(
            stops: try container.decode([Int].self, forKey: .stops),
            style: try container.decode(Style.self, forKey: .style),
            direction: try container.decode(Direction.self, forKey: .direction)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .stops, in: container, debugDescription: "An accent has 1 to 5 stops"
            )
        }
        self = accent
    }

    public var first: Int { stops[0] }
    public var isGradient: Bool { stops.count > 1 }
    public var canAddStop: Bool { stops.count < Self.stopCounts.upperBound }

    /// The accent as saved: builds without gradients save only `accentHex`, so a gradient counts
    /// only while it still starts with it, and a colour such a build picks replaces it.
    public static func saved(_ gradient: AccentGradient?, accentHex: Int) -> AccentGradient {
        if let gradient, gradient.isGradient, gradient.first == rgb(accentHex) { return gradient }
        return AccentGradient(color: accentHex)
    }

    /// The colours of a 3 by 3 mesh, row by row from the top left.
    public var meshColors: [Int] {
        let spots = Self.meshSpots[stops.count - 1]
        return (0..<9).map { index in
            let point = (x: Double(index % 3) / 2, y: Double(index / 3) / 2)
            let distances = spots.map { pow($0.x - point.x, 2) + pow($0.y - point.y, 2) }
            if let spot = distances.firstIndex(of: 0) { return stops[spot] }
            let weights = distances.map { 1 / $0 }
            let total = weights.reduce(0, +)
            return [16, 8, 0].reduce(0) { rgb, shift in
                let channel = zip(stops, weights).reduce(0.0) { $0 + Double(($1.0 >> shift) & 0xFF) * $1.1 }
                return rgb | Int((channel / total).rounded()) << shift
            }
        }
    }

    private static let meshSpots: [[(x: Double, y: Double)]] = [
        [(0.5, 0.5)],
        [(0, 0), (1, 1)],
        [(0, 0), (1, 0), (0.5, 1)],
        [(0, 0), (1, 0), (1, 1), (0, 1)],
        [(0, 0), (1, 0), (1, 1), (0, 1), (0.5, 0.5)],
    ]

    private static func rgb(_ value: Int) -> Int {
        value & 0xFFFFFF
    }
}
