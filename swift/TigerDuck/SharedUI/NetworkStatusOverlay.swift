import SwiftUI

struct NetworkStatusOverlay: View {
    var loadingState: LoadingState

    @State private var visible = false
    @State private var stateId = UUID()

    var body: some View {
        Group {
            switch loadingState {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.textSecondary)

            case .loaded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .opacity(visible ? 1 : 0)

            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)

            case .idle:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: loadingState)
        .onChange(of: loadingState) { _, newValue in
            if newValue == .loaded {
                visible = true
                stateId = UUID()
                let capturedId = stateId
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard capturedId == stateId else { return }
                    withAnimation(.easeOut(duration: 0.5)) {
                        visible = false
                    }
                }
            } else {
                visible = false
            }
        }
    }
}
