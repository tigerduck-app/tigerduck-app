import SwiftUI

struct GlassTextButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .buttonStyle(.bordered)
        }
    }
}
