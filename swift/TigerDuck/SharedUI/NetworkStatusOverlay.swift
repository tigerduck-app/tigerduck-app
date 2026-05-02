import SwiftUI

struct NetworkStatusOverlay: View {
    var loadingState: LoadingState

    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch loadingState {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .tint(.orange)

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
            hideTask?.cancel()
            if newValue == .loaded {
                visible = true
                hideTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.5)) {
                        visible = false
                    }
                }
            } else {
                visible = false
            }
        }
        .onDisappear { hideTask?.cancel() }
    }
}
