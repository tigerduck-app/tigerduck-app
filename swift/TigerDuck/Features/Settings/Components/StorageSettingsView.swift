import SwiftUI

struct StorageSettingsView: View {
    var cleaner: StorageCleaner = .live

    @State private var sizes: StorageSizes?
    @State private var deleting = false
    @State private var confirming: StorageKind?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Section { StorageTotalCard(sizes: sizes) }
            Section(String(localized: "settings_storage_cache")) {
                row(.moodleFiles)
                row(.mail)
            }
            Section(String(localized: "settings_browser_in_app")) {
                row(.websiteData)
            }
        }
        .navigationTitle(String(localized: "settings_storage_title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { sizes = await cleaner.measure() }
        .alert(
            confirming?.deleteConfirmation?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { kind in
            Button(String(localized: "action_cancel"), role: .cancel) {}
            Button(String(localized: "action_delete"), role: .destructive) { delete(kind) }
        } message: { kind in
            Text(kind.deleteConfirmation?.message ?? "")
        }
    }

    private func row(_ kind: StorageKind) -> some View {
        let size = sizes?.bytes[kind]
        // An unmeasured kind keeps its button, since it may still hold data.
        let canDelete = sizes != nil && !deleting && size != 0
        // At accessibility sizes the size goes under the name, which would otherwise break mid-word.
        let texts = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: TigerDuckTheme.Spacing.sm))
        return HStack(spacing: TigerDuckTheme.Spacing.md) {
            StorageIconTile(kind: kind)
            texts {
                Text(kind.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(sizes == nil ? "…" : size.map(StorageSizes.text) ?? "")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Button {
                if kind.confirmsDelete { confirming = kind } else { delete(kind) }
            } label: {
                Image(systemName: "trash")
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // A 44-point target that does not make the row taller than its icon tile.
            .padding(.vertical, -7)
            .disabled(!canDelete)
            .accessibilityLabel(String(format: String(localized: "settings_storage_delete_kind"), kind.title))
        }
    }

    private func delete(_ kind: StorageKind) {
        deleting = true
        Task {
            sizes = await cleaner.delete(kind)
            deleting = false
        }
    }
}

private struct StorageTotalCard: View {
    let sizes: StorageSizes?

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "settings_storage_total"))
                Spacer()
                Text(sizes.map { StorageSizes.text($0.total) } ?? "…")
                    .font(TigerDuckTheme.Typography.title)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            StorageBar(sizes: sizes ?? StorageSizes())
        }
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
    }
}

private struct StorageBar: View {
    let sizes: StorageSizes

    var body: some View {
        let segments = sizes.segments
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(segments, id: \.kind) { segment in
                    Rectangle()
                        .fill(segment.kind.color)
                        .frame(width: proxy.size.width * segment.share)
                }
            }
        }
        .frame(height: 10)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ListFormatter.localizedString(byJoining: segments.map { segment in
            "\(segment.kind.title) \(StorageSizes.text(sizes.bytes[segment.kind] ?? 0))"
        }))
        .accessibilityHidden(segments.isEmpty)
    }
}

private struct StorageIconTile: View {
    let kind: StorageKind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(kind.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension StorageKind {
    var title: String {
        switch self {
        case .moodleFiles: String(localized: "settings_downloaded_files_moodle")
        case .mail: String(localized: "feature_school_mail")
        case .websiteData: String(localized: "settings_storage_browser_data")
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .moodleFiles: "folder.fill"
        case .mail: "envelope.fill"
        case .websiteData: "globe"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .moodleFiles: .orange
        case .mail: .blue
        case .websiteData: .gray
        }
    }

    fileprivate var deleteConfirmation: (title: String, message: String)? {
        switch self {
        case .moodleFiles:
            nil
        case .mail:
            (String(localized: "school_mail_storage_delete_title"), String(localized: "school_mail_storage_delete_message"))
        case .websiteData:
            (String(localized: "settings_storage_browser_data_delete_title"),
             String(localized: "settings_storage_browser_data_delete_message"))
        }
    }
}

extension StorageCleaner {
    /// Each measure walks its folder off the main thread. Website data goes with its whole store,
    /// as at a sign-out, but keeps each site's zoom and desktop choice.
    static var live: StorageCleaner {
        let downloads = MoodleFileDownloads.shared
        return StorageCleaner(stores: [
            .moodleFiles: Store(measure: { await downloads.measure() }, clear: { _ = await downloads.clear() }),
            .mail: .mail(MailAccountManager.shared.cache),
            .websiteData: Store(
                measure: { await BrowserData.storeBytes() },
                clear: { await BrowserData.shared.reset(keepingSiteChoices: true)?.value }
            ),
        ])
    }
}

extension StorageCleaner.Store {
    nonisolated static func mail(_ cache: MailCache) -> Self {
        Self(
            measure: { await Task.detached { cache.totalBytes() }.value },
            clear: { await Task.detached { cache.clearAll() }.value }
        )
    }
}
