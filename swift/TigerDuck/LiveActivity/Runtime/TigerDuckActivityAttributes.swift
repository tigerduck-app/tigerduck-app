import ActivityKit
import Foundation

nonisolated struct TigerDuckActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let snapshot: LiveActivitySnapshot
    }

    let activityId: String
}
