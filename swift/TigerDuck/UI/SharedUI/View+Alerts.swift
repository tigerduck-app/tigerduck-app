import SwiftUI

extension View {
    func notImplementedAlert(isPresented: Binding<Bool>) -> some View {
        alert(String(localized: "coming_soon_title"), isPresented: isPresented) {
            Button(String(localized: "action_got_it"), role: .cancel) { }
        } message: {
            Text(String(localized: "coming_soon_message"))
        }
    }
}
