import SwiftUI

/// Blocking notice for a build the server no longer answers.
///
/// Deliberately unlike the "a newer version is available" nudge in
/// ``UpdatePromptView``: that one is optional and dismissible because the
/// current build still works. This one fires on a 410, which means every
/// backend call from this build now fails, so there is nothing to postpone
/// and a Later button would only hide the reason the app looks broken.
///
/// It still cannot be a hard wall. Plenty of the app is local — the class
/// table, the time machine, cached bulletins — and it would be worse to
/// lock a student out of their own timetable than to let them read it while
/// the sync stays broken. So: no cancel button, but the alert can be
/// dismissed once it has been read, and it comes back the next time a
/// request fails and the view re-appears.
private struct UpdateRequiredAlert: ViewModifier {
    @Environment(\.openURL) private var openURL
    @State private var gate = APIVersionGate.shared
    /// Per-presentation, not persisted: the gate latches for the process,
    /// so without this the alert would re-present the instant it closed.
    /// Scoped to this view so a relaunch says it again.
    @State private var acknowledged = false

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "update_required_title"),
            isPresented: Binding(
                get: { gate.isRetired && !acknowledged },
                set: { presented in
                    if !presented { acknowledged = true }
                }
            )
        ) {
            Button(String(localized: "update_required_action")) {
                openURL(AppURLs.website)
            }
            Button(String(localized: "action_got_it"), role: .cancel) {}
        } message: {
            Text(String(localized: "update_required_message"))
        }
    }
}

extension View {
    /// Present the "this build is too old" notice. Apply once, at the root
    /// of each platform's scene — applying it per-screen would stack one
    /// alert per mounted view.
    func updateRequiredAlert() -> some View {
        modifier(UpdateRequiredAlert())
    }
}
