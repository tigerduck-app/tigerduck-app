import ActivityKit
import Foundation

/// Attributes shared between the app target and the Widget Extension target.
/// Both sides must compile this file; once the extension target exists, add
/// this same source file to its Compile Sources list (handoff doc step 3).
nonisolated struct TigerDuckActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let snapshot: LiveActivitySnapshot
    }

    /// Stable id for the lifetime of the activity. Set to the resolved
    /// snapshot's `sourceId` at creation time.
    let activityId: String
}
