import SwiftUI

struct LibraryQRView: View {
    @State private var viewModel = LibraryQRViewModel()
    @State private var isFullScreen = false
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
        .onDisappear {
            // Skip when the cover is presenting on top of us: the cover
            // shows the same viewModel.qrImage, so we must keep the 30s
            // refresh running or the user sees an expired QR.
            if !isFullScreen {
                viewModel.onDisappear()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.onAppear()
            } else {
                viewModel.onDisappear()
            }
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenQRView(viewModel: viewModel, dismiss: { isFullScreen = false })
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
                .onTapGesture(count: 2) {
                    isFullScreen = true
                }
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

/// Fullscreen QR presentation. Dismissed by an upward or downward drag
/// past `dismissThreshold`. We don't use the system swipe-down dismissal
/// because the user requested either direction.
private struct FullScreenQRView: View {
    let viewModel: LibraryQRViewModel
    let dismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    private static let dismissThreshold: CGFloat = 60

    var body: some View {
        // White background runs corner-to-corner; the image gets a small
        // top inset so the watchOS time strip doesn't overlap QR modules.
        // The full safe-area override on the ZStack lets the matrix
        // claim almost all of the screen. Reads viewModel.qrImage so the
        // refresh timer's updates propagate while the cover is up.
        ZStack {
            Color.white
            if let image = viewModel.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
        }
        .ignoresSafeArea()
        // Hide the system close indicator so it stops landing on top of
        // the matrix. Drag-up or drag-down is the documented dismiss
        // gesture for this presentation.
        .toolbar(.hidden, for: .automatic)
        .offset(y: dragOffset)
        .onChange(of: viewModel.hasCredentials) { _, hasCreds in
            // Credentials wiped (phone logout, TTL purge) — drop the
            // cover so the user lands back on the empty state instead
            // of staring at a stale QR with no way to refresh it.
            if !hasCreds { dismiss() }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    if abs(value.translation.height) > Self.dismissThreshold {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.25)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
}
