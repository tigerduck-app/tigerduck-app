import Foundation

/// Key constants for the WatchConnectivity applicationContext payload.
/// Bumping `Self.version` indicates an incompatible payload — receivers
/// SHOULD still attempt to decode but MAY discard if unsupported.
nonisolated public enum WatchWireFormat {
    public static let version = 1

    public enum Key {
        public static let version    = "v"
        public static let courses    = "courses"
        public static let accentHex  = "accentHex"
        public static let syncedAtMs = "syncedAtMs"
        public static let loggedIn   = "loggedIn"
        public static let languageTag = "languageTag"
        /// `VisualPreset.rawValue` — controls whether the watch course
        /// cards render in TigerDuck (course-colour-tinted) or Apple
        /// (neutral surface with course colour as a small accent stripe)
        /// styling. Mirrors the phone's `AppState.visualPreset` so the two
        /// surfaces stay in lockstep.
        public static let visualPreset = "visualPreset"
        /// JSON-encoded `ClockOverride`. Optional; only present in DEBUG
        /// builds with an active debug time override. Encoded as a JSON
        /// string (rather than a nested dict) to keep watch decoding
        /// path-independent of the `ClockOverride` type when the watch
        /// target hasn't been updated yet.
        public static let clockOverride = "clockOverride"
    }

    public enum MessageKind {
        public static let syncRequest = "syncRequest"
    }

    public enum MessageKey {
        public static let kind = "kind"
    }

    /// User-info kinds delivered via `WCSession.transferUserInfo` —
    /// separate from `MessageKind` (which is for `sendMessage` short-circuit
    /// requests) and from `Key` (which is for `updateApplicationContext`).
    public enum UserInfoKind {
        public static let libraryCredential = "libraryCredential"
    }

    /// Keys inside a `UserInfoKind.libraryCredential` user-info dict.
    public enum LibraryCredentialKey {
        /// Set to `UserInfoKind.libraryCredential`.
        public static let kind = "kind"
        /// JSON-encoded `WatchLibraryCredentialPayload`.
        public static let payload = "payload"
    }
}
