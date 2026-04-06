import SwiftUI

extension View {
    func assignmentBadge(show: Bool, iconSize: CGFloat = 14, padding: CGFloat = 7) -> some View {
        overlay(alignment: .bottomTrailing) {
            if show {
                Image(systemName: "book.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(Color.gray.opacity(0.5))
                    .padding([.bottom, .trailing], padding)
                    .accessibilityHidden(true)
            }
        }
    }

    func notImplementedAlert(isPresented: Binding<Bool>) -> some View {
        alert("快了快了", isPresented: isPresented) {
            Button("收到！", role: .cancel) { }
        } message: {
            Text("此功能尚未實現，敬請期待～")
        }
    }
}

