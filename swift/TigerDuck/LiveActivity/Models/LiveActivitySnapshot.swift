import Foundation

nonisolated struct LiveActivitySnapshot: Codable, Equatable, Hashable, Sendable {
    let scenario: LiveActivityScenarioKind
    let title: String
    let subtitle: String
    let locationText: String?
    let instructor: String?
    let countdownTarget: Date?
    let progressStart: Date?
    let accentHex: Int
    let deepLink: URL?
    let sourceId: String

    var composedActivityId: String {
        "\(scenario.rawValue)::\(sourceId)"
    }
}
