import SwiftUI

private struct UpdateRequiredAlert: ViewModifier {
    @Environment(\.openURL) private var openURL
    @State private var gate = APIVersionGate.shared
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
    func updateRequiredAlert() -> some View {
        modifier(UpdateRequiredAlert())
    }
}
