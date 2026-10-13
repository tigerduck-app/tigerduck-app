import SwiftUI

/// Blocking notice for a build whose API version the server has retired.
///
/// The ``UpdatePromptView`` nudge is optional because the build still works.
/// A 410 means every backend call from this build fails, so a Later button
/// would only hide why the app looks broken. Nor is this a hard wall: the
/// class table, time machine and cached bulletins are local, and a student
/// should still read their timetable. It can be dismissed once read, and
/// returns the next time a request fails and the view re-appears.
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
