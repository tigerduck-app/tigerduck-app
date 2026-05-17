import Foundation

/// Lossless `[String: Any]` <-> `WatchSnapshot` codec for the
/// WatchConnectivity applicationContext payload. Wire keys are defined in
/// `WatchWireFormat`.
public enum WatchPayloadCodec {

    public enum DecodingError: Swift.Error, Equatable {
        case missingRequiredKey(String)
        case invalidType(String)
    }

    private enum CourseKey {
        static let id           = "id"
        static let courseNo     = "courseNo"
        static let name         = "name"
        static let teacher      = "teacher"
        static let classroom    = "classroom"
        static let colorHex     = "colorHex"
        static let weekday      = "weekday"
        static let startHHmm    = "startHHmm"
        static let endHHmm      = "endHHmm"
        static let periodLabel  = "periodLabel"
    }

    // MARK: Encode

    public static func encode(_ snapshot: WatchSnapshot) throws -> [String: Any] {
        var dict: [String: Any] = [
            WatchWireFormat.Key.version:    snapshot.version,
            WatchWireFormat.Key.courses:    snapshot.courses.map(encodeCourse),
            WatchWireFormat.Key.accentHex:  snapshot.accentHex,
            WatchWireFormat.Key.syncedAtMs: snapshot.syncedAtMs,
            WatchWireFormat.Key.loggedIn:   snapshot.loggedIn,
        ]
        if let tag = snapshot.languageTag {
            dict[WatchWireFormat.Key.languageTag] = tag
        }
        if let json = snapshot.clockOverrideJSON {
            dict[WatchWireFormat.Key.clockOverride] = json
        }
        return dict
    }

    private static func encodeCourse(_ c: WatchCourse) -> [String: Any] {
        [
            CourseKey.id:          c.id,
            CourseKey.courseNo:    c.courseNo,
            CourseKey.name:        c.name,
            CourseKey.teacher:     c.teacher,
            CourseKey.classroom:   c.classroom,
            CourseKey.colorHex:    c.colorHex,
            CourseKey.weekday:     c.weekday,
            CourseKey.startHHmm:   c.startHHmm,
            CourseKey.endHHmm:     c.endHHmm,
            CourseKey.periodLabel: c.periodLabel,
        ]
    }

    // MARK: Decode

    public static func decode(_ dict: [String: Any]) throws -> WatchSnapshot {
        guard let raw = dict[WatchWireFormat.Key.courses] else {
            throw DecodingError.missingRequiredKey(WatchWireFormat.Key.courses)
        }
        guard let courseDicts = raw as? [[String: Any]] else {
            throw DecodingError.invalidType(WatchWireFormat.Key.courses)
        }
        let courses = try courseDicts.map(decodeCourse)

        let version     = (dict[WatchWireFormat.Key.version] as? Int) ?? WatchWireFormat.version
        let accentHex   = (dict[WatchWireFormat.Key.accentHex] as? String) ?? WatchSnapshot.defaultAccentHex
        let syncedAtMs  = int64(dict[WatchWireFormat.Key.syncedAtMs]) ?? 0
        let loggedIn    = (dict[WatchWireFormat.Key.loggedIn] as? Bool) ?? false
        let languageTag = dict[WatchWireFormat.Key.languageTag] as? String
        let clockJSON   = dict[WatchWireFormat.Key.clockOverride] as? String

        return WatchSnapshot(
            version: version,
            courses: courses,
            accentHex: accentHex,
            syncedAtMs: syncedAtMs,
            loggedIn: loggedIn,
            languageTag: languageTag,
            clockOverrideJSON: clockJSON
        )
    }

    private static func decodeCourse(_ dict: [String: Any]) throws -> WatchCourse {
        func req<T>(_ key: String) throws -> T {
            guard let any = dict[key] else { throw DecodingError.missingRequiredKey(key) }
            guard let v = any as? T else { throw DecodingError.invalidType(key) }
            return v
        }
        return WatchCourse(
            id:          try req(CourseKey.id),
            courseNo:    try req(CourseKey.courseNo),
            name:        try req(CourseKey.name),
            teacher:     try req(CourseKey.teacher),
            classroom:   try req(CourseKey.classroom),
            colorHex:    try req(CourseKey.colorHex),
            weekday:     try req(CourseKey.weekday),
            startHHmm:   try req(CourseKey.startHHmm),
            endHHmm:     try req(CourseKey.endHHmm),
            periodLabel: try req(CourseKey.periodLabel)
        )
    }

    // Survives plist/NSNumber round-tripping that WCSession performs.
    private static func int64(_ any: Any?) -> Int64? {
        if let n = any as? Int64    { return n }
        if let n = any as? Int      { return Int64(n) }
        if let n = any as? NSNumber { return n.int64Value }
        return nil
    }
}
