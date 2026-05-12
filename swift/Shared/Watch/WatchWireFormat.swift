import Foundation

/// Key constants for the WatchConnectivity applicationContext payload.
/// Bumping `Self.version` indicates an incompatible payload — receivers
/// SHOULD still attempt to decode but MAY discard if unsupported.
public enum WatchWireFormat {
    public static let version = 1

    public enum Key {
        public static let version    = "v"
        public static let courses    = "courses"
        public static let accentHex  = "accentHex"
        public static let syncedAtMs = "syncedAtMs"
        public static let loggedIn   = "loggedIn"
        public static let languageTag = "languageTag"
    }

    public enum MessageKind {
        public static let syncRequest = "syncRequest"
    }

    public enum MessageKey {
        public static let kind = "kind"
    }
}
