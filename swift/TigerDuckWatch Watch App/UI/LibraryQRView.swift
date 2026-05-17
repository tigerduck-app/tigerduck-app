import SwiftUI

struct LibraryQRView: View {
    @State private var viewModel = LibraryQRViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !viewModel.hasCredentials {
                    emptyState
                } else {
                    qrSection
                    countdownSection
                    if let message = viewModel.errorMessage {
                        errorRow(message)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(String(localized: "watch_library_title"))
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.onAppear()
            } else {
                viewModel.onDisappear()
            }
        }
    }

    // MARK: - States

    private var emptyState: some View {
        ContentUnavailableView(
            String(localized: "watch_library_signin_prompt"),
            systemImage: "iphone.gen3"
        )
    }

    @ViewBuilder
    private var qrSection: some View {
        if let image = viewModel.qrImage {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 4)
        } else if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var countdownSection: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.countdown) / 30.0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: viewModel.countdown)
            }
            .frame(width: 12, height: 12)

            Text(String(format: String(localized: "watch_library_refresh_in_seconds"), viewModel.countdown))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let u = viewModel.username {
                Spacer(minLength: 4)
                Text(u)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 2)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.top, 4)
    }
}
