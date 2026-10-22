import Foundation

public nonisolated enum VisualPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case `default` = "default"

    case iosInspired = "iosInspired"

    case tat = "tat"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .default: return "TigerDuck"
        case .iosInspired: return "Apple"
        case .tat: return "TAT"
        }
    }

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = VisualPreset(rawValue: rawValue) ?? .default
    }
}
