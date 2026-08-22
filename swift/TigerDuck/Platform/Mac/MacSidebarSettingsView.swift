#if os(macOS)
import SwiftUI

/// Pin / unpin / reorder the features that appear in the Mac sidebar.
///
/// Writes straight through to `AppState.macConfiguredTabs`, which is a
/// Mac-only preference. The iOS tab bar uses `configuredTabs` and is
/// capped at four user tabs — Mac sidebar edits must not leak into it.
/// Library-related features are filtered out — they don't exist on Mac
/// per `AppFeature.macHiddenFeatures`.
struct MacSidebarSettingsView: View {
    @Environment(AppState.self) private var appState

    private var pinned: [AppFeature] {
        appState.macConfiguredTabs.filter { $0.isAvailableOnMac }
    }

    private var available: [AppFeature] {
        AppFeature.allCases.filter {
            $0.isImplemented && $0.isAvailableOnMac && !appState.macConfiguredTabs.contains($0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "desktop_settings_sidebar_description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HSplitView {
                section(
                    title: String(localized: "desktop_settings_sidebar_pinned"),
                    systemImage: "pin.fill",
                    items: pinned,
                    emptyMessage: String(localized: "desktop_settings_sidebar_empty_pinned")
                ) { feature, index in
                    pinnedRow(feature, index: index, total: pinned.count)
                }

                section(
                    title: String(localized: "desktop_settings_sidebar_available"),
                    systemImage: "square.grid.2x2",
                    items: available,
                    emptyMessage: String(localized: "desktop_settings_sidebar_empty_available")
                ) { feature, _ in
                    availableRow(feature)
                }
            }
            .frame(minHeight: 280)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section<Row: View>(
        title: String,
        systemImage: String,
        items: [AppFeature],
        emptyMessage: String,
        @ViewBuilder row: @escaping (AppFeature, Int) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.leading, 4)
            if items.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.top, 4)
            } else {
                List {
                    ForEach(items.indices, id: \.self) { index in
                        row(items[index], index)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 240)
    }

    private func pinnedRow(_ feature: AppFeature, index: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            Label(feature.displayName, systemImage: feature.iconName)
            Spacer()
            Button {
                moveUp(at: index)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(String(localized: "desktop_settings_sidebar_move_up"))

            Button {
                moveDown(at: index)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == total - 1)
            .help(String(localized: "desktop_settings_sidebar_move_down"))

            Button {
                unpin(feature)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "desktop_settings_sidebar_remove"))
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
            .help(String(localized: "desktop_settings_sidebar_pin"))
        }
    }

    private func pin(_ feature: AppFeature) {
        guard !appState.macConfiguredTabs.contains(feature) else { return }
        appState.macConfiguredTabs.append(feature)
    }

    private func unpin(_ feature: AppFeature) {
        appState.macConfiguredTabs.removeAll { $0 == feature }
    }

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

    /// Reorder pinned features one step. `visible` index space; any
    /// Mac-hidden pins (e.g. a Library item previously pinned on
    /// iPhone) ride along unchanged at the tail so a Mac reorder
    /// doesn't disturb non-Mac entries.
    private func rearrange(_ mutate: (inout [AppFeature]) -> Void) {
        var visible = appState.macConfiguredTabs.filter { $0.isAvailableOnMac }
        let hidden = appState.macConfiguredTabs.filter { !$0.isAvailableOnMac }
        mutate(&visible)
        appState.macConfiguredTabs = visible + hidden
    }
}

#endif
