// Lives in the watch target but is symmetrical: the phone uses the
// same encode/decode logic via multi-target membership.
import Foundation

public enum WatchPayloadCodec {

    public enum Error: Swift.Error, Equatable {
        case missingField(String)
        case wrongType(String)
    }

    /// Encode a snapshot for `WCSession.updateApplicationContext`.
    public static func encode(_ snapshot: WatchSnapshot) throws -> [String: Any] {
        let coursesData = try JSONEncoder().encode(snapshot.courses)
        let coursesArray = try JSONSerialization.jsonObject(with: coursesData) as? [[String: Any]]
        guard let courses = coursesArray else {
            throw Error.wrongType(WatchWireFormat.Key.courses)
        }
        var dict: [String: Any] = [
            WatchWireFormat.Key.version: snapshot.version,
            WatchWireFormat.Key.courses: courses,
            WatchWireFormat.Key.accentHex: snapshot.accentHex,
            WatchWireFormat.Key.syncedAtMs: NSNumber(value: snapshot.syncedAtMs),
            WatchWireFormat.Key.loggedIn: snapshot.loggedIn,
        ]
        if let tag = snapshot.languageTag {
            dict[WatchWireFormat.Key.languageTag] = tag
        }
        return dict
    }

    /// Decode an incoming applicationContext into a `WatchSnapshot`.
    public static func decode(_ dict: [String: Any]) throws -> WatchSnapshot {
        guard let coursesAny = dict[WatchWireFormat.Key.courses] else {
            throw Error.missingField(WatchWireFormat.Key.courses)
        }
        guard let coursesArray = coursesAny as? [[String: Any]] else {
            throw Error.wrongType(WatchWireFormat.Key.courses)
        }
        let coursesData = try JSONSerialization.data(withJSONObject: coursesArray)
        let courses = try JSONDecoder().decode([WatchCourse].self, from: coursesData)

        let version = (dict[WatchWireFormat.Key.version] as? Int) ?? WatchWireFormat.version
        let accent = (dict[WatchWireFormat.Key.accentHex] as? String) ?? WatchSnapshot.defaultAccentHex
        let syncedAtMs = (dict[WatchWireFormat.Key.syncedAtMs] as? NSNumber)?.int64Value
            ?? (dict[WatchWireFormat.Key.syncedAtMs] as? Int64)
            ?? 0
        let loggedIn = (dict[WatchWireFormat.Key.loggedIn] as? Bool) ?? false
        let languageTag = dict[WatchWireFormat.Key.languageTag] as? String

        return WatchSnapshot(
            version: version,
            courses: courses,
            accentHex: accent,
            syncedAtMs: syncedAtMs,
            loggedIn: loggedIn,
            languageTag: languageTag
        )
    }
}
