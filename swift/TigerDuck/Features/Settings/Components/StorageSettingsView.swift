import SwiftUI

struct StorageSettingsView: View {
    var cleaner: StorageCleaner = .live

    @State private var sizes: StorageSizes?
    @State private var deleting = false
    @State private var confirming: StorageKind?

    var body: some View {
        List {
            Section { StorageTotalCard(sizes: sizes) }
            ForEach(StorageKind.sections.indices, id: \.self) { index in
                let section = StorageKind.sections[index]
                Section(section.title) {
                    ForEach(section.kinds, id: \.self, content: row)
                }
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
            if let message = kind.deleteConfirmation?.message { Text(message) }
        }
    }

    private func row(_ kind: StorageKind) -> some View {
        StorageRow(kind: kind, sizes: sizes, deleting: deleting) {
            if kind.confirmsDelete { confirming = kind } else { delete(kind) }
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

struct StorageKindSection: View {
    let kinds: [StorageKind]
    var cleaner: StorageCleaner = .live

    @State private var sizes: StorageSizes?
    @State private var deleting = false
    @State private var confirming: StorageKind?

    var body: some View {
        Section(String(localized: "settings_storage_title")) {
            ForEach(kinds, id: \.self) { kind in
                StorageRow(kind: kind, sizes: sizes, deleting: deleting) {
                    if kind.confirmsDelete { confirming = kind } else { delete(kind) }
                }
            }
            .alert(
                confirming?.deleteConfirmation?.title ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                presenting: confirming
            ) { kind in
                Button(String(localized: "action_cancel"), role: .cancel) {}
                Button(String(localized: "action_delete"), role: .destructive) { delete(kind) }
            } message: { kind in
                if let message = kind.deleteConfirmation?.message { Text(message) }
            }
        }
        .task { sizes = await cleaner.only(kinds).measure() }
    }

    private func delete(_ kind: StorageKind) {
        deleting = true
        Task {
            sizes = await cleaner.only(kinds).delete(kind)
            deleting = false
        }
    }
}

private struct StorageRow: View {
    let kind: StorageKind
    let sizes: StorageSizes?
    let deleting: Bool
    let onDelete: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let size = sizes?.bytes[kind]
        // An unmeasured kind keeps its button, since it may still hold data.
        let canDelete = sizes != nil && !deleting && size != 0
        // At accessibility sizes the size goes under the name, which would otherwise break mid-word.
        let texts = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: TigerDuckTheme.Spacing.sm))
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            StorageIconTile(kind: kind)
            texts {
                Text(kind.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(sizes == nil ? "…" : size.map { StorageSizes.text($0) } ?? "")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
            }
            Button(action: onDelete) {
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
}

private extension StorageCleaner {
    func only(_ kinds: [StorageKind]) -> StorageCleaner {
        StorageCleaner(stores: stores.filter { kinds.contains($0.key) })
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
    static var sections: [(title: String, kinds: [StorageKind])] {
        [
            (String(localized: "settings_downloaded_files_title"), [.moodleFiles, .moodleData, .mailAttachments]),
            (String(localized: "feature_school_mail"), [.mailCache, .mail]),
            (String(localized: "settings_browser_in_app"), [.browserDownloads, .websiteData]),
        ]
    }

    var title: String {
        switch self {
        case .moodleFiles: String(localized: "settings_downloaded_files_moodle")
        case .moodleData: String(localized: "settings_storage_moodle_data")
        case .mailAttachments: String(localized: "settings_downloaded_files_mail")
        case .mailCache: String(localized: "school_mail_cache_size")
        case .mail: String(localized: "school_mail_storage_title")
        case .browserDownloads: String(localized: "browser_downloads")
        case .websiteData: String(localized: "settings_storage_browser_data")
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .moodleFiles: "folder.fill"
        case .moodleData: "person.crop.circle.fill"
        case .mailAttachments: "paperclip"
        case .mailCache: "envelope.fill"
        case .mail: "tray.fill"
        case .browserDownloads: "arrow.down.circle.fill"
        case .websiteData: "globe"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .moodleFiles: .orange
        case .moodleData: .yellow
        case .mailAttachments: .teal
        case .mailCache: .blue
        case .mail: .purple
        case .browserDownloads: .green
        case .websiteData: .gray
        }
    }

    var deleteConfirmation: (title: String, message: String?)? {
        switch self {
        case .moodleFiles, .moodleData, .mailAttachments, .mailCache:
            nil
        case .mail:
            (String(localized: "school_mail_storage_delete_title"), String(localized: "school_mail_storage_delete_message"))
        case .browserDownloads:
            (String(localized: "browser_downloads_delete_title"), nil)
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
        let moodleData = MoodleUserData.shared
        let mail = MailAccountManager.shared.cache
        let browserDownloads = SavedDownloads.browser
        return StorageCleaner(stores: [
            .moodleFiles: Store(measure: { await downloads.measure() }, clear: { _ = await downloads.clear() }),
            .moodleData: Store(measure: { await moodleData.measure() }, clear: { await moodleData.clear() }),
            .mailAttachments: .mail(mail, .attachments),
            .mailCache: .mail(mail, .lists),
            .mail: .mail(mail, .messages),
            .browserDownloads: Store(measure: { await browserDownloads.measure() }, clear: { await browserDownloads.clear() }),
            .websiteData: Store(
                measure: { await BrowserData.storeBytes() },
                clear: { await BrowserData.shared.reset(keepingSiteChoices: true)?.value }
            ),
        ])
    }
}

extension StorageCleaner.Store {
    nonisolated static func mail(_ cache: MailCache, _ part: MailCache.Part) -> Self {
        Self(
            measure: { await Task.detached { cache.bytes(in: part) }.value },
            clear: { await Task.detached { cache.clear(part) }.value }
        )
    }
}
