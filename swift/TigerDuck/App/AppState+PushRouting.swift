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
