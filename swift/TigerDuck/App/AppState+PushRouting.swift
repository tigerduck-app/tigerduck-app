// Custom-push tap routing — split out of AppState.swift, iOS only.
//
// `NotificationDelegate` resolves an operator-issued push tap into one of
// these targets and writes to the paired stored property — still on
// `AppState` itself, since extensions can't hold stored properties; this
// file is just the target types plus the shown/seen bookkeeping around
// the popup variant. Not to be confused with AppState+PushServer.swift,
// which is registration and preference plumbing, not tap handling.

import SwiftUI
import Defaults

extension AppState {

    #if os(iOS)
    /// In-process deep-link targets resolved from a custom-push tap. The
    /// `NotificationDelegate` writes here; the destination view observes
    /// and clears the value once it has acted on it.
    enum DeepLink: Equatable {
        case bulletin(Int)
        /// A School Mail notification. `uid == nil` (the "N 封新郵件" summary, the sign-in
        /// failure notice) opens the folder list.
        case schoolMail(folder: String, uid: UInt32?)
    }

    /// Parses a School Mail notification tap into a `DeepLink`. Returns `nil` for any
    /// other `kind` (bulletin, popup, or unrecognized) so callers can chain it after
    /// their own routing without misclassifying unrelated pushes.
    static func schoolMailDeepLink(from userInfo: [AnyHashable: Any]) -> DeepLink? {
        guard userInfo["kind"] as? String == MailConstants.notificationKind else { return nil }
        let folder = userInfo["folder"] as? String ?? MailConstants.inbox
        return .schoolMail(folder: folder, uid: schoolMailUID(from: userInfo["uid"]))
    }

    /// Decode `uid` from a JSON-bridged userInfo value the same tolerant way
    /// `TigerDuckApp`'s `bulletinId(from:)` decodes `bulletin_id`: APNs / FCM / intermediate
    /// relays bridge JSON numbers inconsistently — some land as an Int-tagged NSNumber that
    /// succeeds `as? Int`, others as a Double-tagged NSNumber where `as? Int` fails, and a few
    /// re-encode the value as a quoted string. `UInt32(exactly:)` (rather than a truncating or
    /// trapping initializer) also turns a negative or too-large value into `nil` instead of
    /// wrapping or crashing — `schoolMailDeepLink` already treats `nil` as "open the folder list".
    private static func schoolMailUID(from raw: Any?) -> UInt32? {
        if let n = raw as? Int { return UInt32(exactly: n) }
        if let n = raw as? NSNumber { return UInt32(exactly: n.int64Value) }
        if let s = raw as? String, let n = Int64(s) { return UInt32(exactly: n) }
        return nil
    }

    /// Payload for an operator-issued popup push. `id` is the server-side
    /// notification id and is also used by SwiftUI's `.alert(_:isPresented:
    /// presenting:)` for view identity, so re-tapping the same notification
    /// while the previous alert is still on screen does not double-present.
    struct ServerPopupPayload: Equatable, Identifiable {
        let id: String   // notification_id
        let title: String
        let body: String
    }

    /// Has the user already been shown the popup for this notification id?
    /// Persisted via `Defaults[.shownServerPopupIds]` as a FIFO list
    /// capped at 100 entries. Read-only — call `markServerPopupShown`
    /// from the alert's dismiss action so an alert that was suppressed
    /// (e.g. by a competing onboarding sheet) isn't permanently deduped.
    @MainActor
    func isServerPopupShown(_ id: String) -> Bool {
        Defaults[.shownServerPopupIds].contains(id)
    }

    /// Record that the user has actually seen the popup for `id`. Only
    /// call this from the alert dismiss path — calling it at routing
    /// time risks marking a popup as seen when its alert never rendered
    /// (mid-onboarding, modal collision, etc.), permanently suppressing
    /// it on future taps.
    @MainActor
    func markServerPopupShown(_ id: String) {
        var seen = Defaults[.shownServerPopupIds]
        if seen.contains(id) { return }
        seen.append(id)
        if seen.count > 100 {
            seen.removeFirst(seen.count - 100)
        }
        Defaults[.shownServerPopupIds] = seen
    }
    #endif

}
