#if os(macOS)
import SwiftUI

/// The "More" sidebar destination: lets the user pin / unpin / reorder
/// the features that appear in the Mac sidebar.
///
/// Editing happens in place, no separate mode toggle — Mac apps with
/// sidebar customisation (Mail, Finder Tags) follow the same direct
/// manipulation pattern. Changes write straight through to
/// `AppState.configuredTabs`, which is persisted via Defaults and shared
/// with the iOS app, so a user who unpins a feature on Mac will see the
/// same sidebar trimming next time they open the iPhone tab bar.
struct MacMoreView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            pinnedSection
            availableSection
            if appState.authService.hasStoredCredentials {
                logoutSection
            }
        }
        .listStyle(.inset)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Sections

    @ViewBuilder
    private var pinnedSection: some View {
        let items = pinned
        Section {
            if items.isEmpty {
                Text("Nothing pinned. Add features from the Available section below.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.indices, id: \.self) { index in
                    pinnedRow(items[index], index: index, total: items.count)
                }
            }
        } header: {
            Label("Pinned to Sidebar", systemImage: "pin.fill")
        } footer: {
            Text("Use the arrows to reorder. Changes sync with the iPhone tab bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        let items = available
        Section {
            if items.isEmpty {
                Text("Every feature is already pinned.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.indices, id: \.self) { index in
                    availableRow(items[index])
                }
            }
        } header: {
            Label("Available Features", systemImage: "square.grid.2x2")
        }
    }

    @ViewBuilder
    private var logoutSection: some View {
        Section {
            Button(role: .destructive) {
                appState.logoutNTUST()
            } label: {
                Label("Sign out of NTUST", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    // MARK: - Rows

    private func pinnedRow(_ feature: AppFeature, index: Int, total: Int) -> some View {
        HStack(spacing: 12) {
            Label(feature.displayName, systemImage: feature.iconName)
            Spacer()
            Button {
                moveUp(at: index)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move up")

            Button {
                moveDown(at: index)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == total - 1)
            .help("Move down")

            Button {
                unpin(feature)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove from sidebar")
        }
    }

    private func availableRow(_ feature: AppFeature) -> some View {
        HStack {
            Label(feature.displayName, systemImage: feature.iconName)
            Spacer()
            Button {
                pin(feature)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help("Pin to sidebar")
        }
    }

    // MARK: - Derived lists

    private var pinned: [AppFeature] {
        appState.configuredTabs.filter { $0.isAvailableOnMac }
    }

    private var available: [AppFeature] {
        AppFeature.allCases.filter {
            $0.isImplemented && $0.isAvailableOnMac && !appState.configuredTabs.contains($0)
        }
    }

    // MARK: - Mutations

    private func pin(_ feature: AppFeature) {
        guard !appState.configuredTabs.contains(feature) else { return }
        appState.configuredTabs.append(feature)
    }

    private func unpin(_ feature: AppFeature) {
        appState.configuredTabs.removeAll { $0 == feature }
    }

    /// Reorder pinned features one step. `visible` index space; any
    /// cross-platform pins that aren't surfaced on Mac (e.g. a Library
    /// item the user previously pinned on iPhone) ride along
    /// unchanged at the tail so a Mac reorder doesn't disturb iOS-only
    /// pins.
    private func moveUp(at index: Int) {
        guard index > 0 else { return }
        rearrange { visible in visible.swapAt(index, index - 1) }
    }

    private func moveDown(at index: Int) {
        rearrange { visible in
            guard index < visible.count - 1 else { return }
            visible.swapAt(index, index + 1)
        }
    }

    private func rearrange(_ mutate: (inout [AppFeature]) -> Void) {
        var visible = appState.configuredTabs.filter { $0.isAvailableOnMac }
        let hidden = appState.configuredTabs.filter { !$0.isAvailableOnMac }
        mutate(&visible)
        appState.configuredTabs = visible + hidden
    }
}
#endif
