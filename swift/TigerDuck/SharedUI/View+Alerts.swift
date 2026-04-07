import SwiftUI

extension View {
    func notImplementedAlert(isPresented: Binding<Bool>) -> some View {
        alert("快了快了", isPresented: isPresented) {
            Button("收到！", role: .cancel) { }
        } message: {
            Text("此功能尚未實現，敬請期待～")
        }
    }
}
