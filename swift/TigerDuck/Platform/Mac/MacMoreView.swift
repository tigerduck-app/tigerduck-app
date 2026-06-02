#if os(macOS)
import SwiftUI

/// The "More" sidebar destination.
///
/// Mirrors the iPhone More tab: a grouped, navigable list of every
/// feature the app surfaces (Pages, Academic, Life, Language, System),
/// with a per-row pin/unpin badge so the user can pin straight from
/// here without dipping into Settings. Implemented features open the
/// real feature view inside a NavigationStack; unimplemented ones show
/// the placeholder body so the user can see what's coming.
///
/// Library-related entries are filtered out via
/// `AppFeature.isAvailableOnMac` — Library, Discussion Room, and
/// Library Lecture never appear here. Settings is intentionally
/// omitted: it lives at the sidebar bottom (`SettingsLink`) and the
/// detailed pin / time-override controls are in the Settings window.
struct MacMoreView: View {
    @Environment(AppState.self) private var appState

    @State private var path = NavigationPath()

    /// One row per feature (the iPhone uses the same `moreFeatures`
    /// list — we just filter it through `isAvailableOnMac`).
    private var visibleFeatures: [AppFeature] {
        AppFeature.moreFeatures.filter { $0.isAvailableOnMac }
    }

    private var sections: [(FeatureCategory, [AppFeature])] {
        let grouped = Dictionary(grouping: visibleFeatures, by: { $0.category })
        return FeatureCategory.allCases.compactMap { category in
            let items = grouped[category] ?? []
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    ForEach(sections, id: \.0.id) { category, items in
                        categorySection(title: category.displayName, items: items)
                    }
                }
                .macReadableContent(maxWidth: MacContentWidth.narrow)
            }
            .navigationDestination(for: AppFeature.self) { feature in
                MacFeatureDetail(feature: feature)
                    .navigationTitle(feature.displayName)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "feature_more"))
                .font(.largeTitle.bold())
            Text(String(localized: "desktop_more_subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func categorySection(title: String, items: [AppFeature]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, feature in
                    featureRow(feature)
                    if index < items.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }

    private func featureRow(_ feature: AppFeature) -> some View {
        HStack(spacing: 14) {
            Image(systemName: feature.iconName)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                if !feature.isImplemented {
                    Text(String(localized: "desktop_more_not_implemented"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if feature.isImplemented {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard feature.isImplemented else { return }
            path.append(feature)
        }
    }

}
#endif
