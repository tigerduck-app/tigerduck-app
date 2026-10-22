import Foundation

nonisolated public enum WatchWireFormat {
    public static let version = 1

    public enum Key {
        public static let version    = "v"
        public static let courses    = "courses"
        public static let accentHex  = "accentHex"
        public static let syncedAtMs = "syncedAtMs"
        public static let loggedIn   = "loggedIn"
        public static let languageTag = "languageTag"
        public static let visualPreset = "visualPreset"
        public static let clockOverride = "clockOverride"
        public static let quietDays = "quietDays"
    }

    public enum MessageKind {
        public static let syncRequest = "syncRequest"
        public static let libraryQRRequest = "libraryQRRequest"
    }

    public enum LibraryQRKey {
        public static let payload = "payload"
        public static let remaining = "remaining"
        public static let error = "error"
    }

    public enum MessageKey {
        public static let kind = "kind"
    }

    public enum UserInfoKind {
        public static let libraryCredential = "libraryCredential"
    }

    public enum LibraryCredentialKey {
        public static let kind = "kind"
        public static let payload = "payload"
    }
}
