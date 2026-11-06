import SwiftUI

struct BrowserDownloadsView: View {
    let page: BrowserPage

    @State private var files = MoodleFileOpener()
    @State private var confirmsClear = false
    @State private var showsPicker = false

    private var downloads: BrowserDownloads { page.downloads }

    var body: some View {
        List {
            ForEach(downloads.items) { item in
                switch item.state {
                case .running: running(item)
                case .failed: failed(item)
                }
            }
            ForEach(downloads.saved, content: saved)
        }
        .overlay {
            if downloads.items.isEmpty && downloads.saved.isEmpty {
                ContentUnavailableView(String(localized: "browser_downloads_empty"), systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle(String(localized: "browser_downloads"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "browser_downloads_clear")) { confirmsClear = true }
                    .disabled(!downloads.canClear)
            }
        }
        .alert(String(localized: "browser_downloads_delete_title"), isPresented: $confirmsClear) {
            Button(String(localized: "action_cancel"), role: .cancel) {}
            Button(String(localized: "action_delete"), role: .destructive) { Task { await downloads.clear() } }
        }
        .task { await downloads.reload() }
        .moodleFilePresentation(files)
        .sheet(isPresented: $showsPicker) { FilesFolderPicker(folder: downloads.store.folder).ignoresSafeArea() }
    }

    private func running(_ item: BrowserDownloads.Item) -> some View {
        let amount = [item.received, item.expected].compactMap { $0.map(Self.size) }.joined(separator: " / ")
        return HStack(spacing: TigerDuckTheme.Spacing.md) {
            BrowserDownloadLabel(name: item.name) {
                if let expected = item.expected, expected > 0 {
                    ProgressView(value: Double(item.received), total: Double(expected))
                        .accessibilityLabel(String(localized: "browser_download_progress_label"))
                }
                Text(String(format: String(localized: "browser_download_progress"), amount))
            }
            accessory("xmark.circle", String(localized: "browser_download_cancel")) { downloads.cancel(item.id) }
        }
    }

    private func failed(_ item: BrowserDownloads.Item) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            BrowserDownloadLabel(name: item.name) {
                Text(String(localized: "browser_download_failed")).foregroundStyle(.red)
            }
            .accessibilityElement(children: .combine)
            accessory("arrow.clockwise", String(localized: "action_retry")) { page.retryDownload(item) }
        }
    }

    private func saved(_ entry: SavedDownloads.Entry) -> some View {
        let file = downloads.store.url(of: entry)
        let open: () -> Void = { files.show(downloaded: file, mimeType: nil) }
        let remove: () -> Void = { Task { await downloads.remove(entry) } }
        return HStack(spacing: TigerDuckTheme.Spacing.md) {
            Button(action: open) {
                BrowserDownloadLabel(name: entry.name) {
                    Text(String(format: String(localized: "browser_download_done"), Self.size(Int64(entry.size))))
                }
            }
            .buttonStyle(.plain)
            accessory("magnifyingglass", String(localized: "browser_downloads_open_in_files"), openFolder)
        }
        .contextMenu {
            Button(String(localized: "browser_download_open"), systemImage: "doc", action: open)
            Button(String(localized: "browser_share_short"), systemImage: "square.and.arrow.up") { files.share(link: file) }
            Button(String(localized: "browser_downloads_open_in_files"), systemImage: "folder", action: openFolder)
            Divider()
            Button(String(localized: "action_remove"), systemImage: "trash", role: .destructive, action: remove)
        }
        .swipeActions {
            Button(String(localized: "action_remove"), systemImage: "trash", role: .destructive, action: remove)
        }
    }

    private func accessory(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private func openFolder() {
        let folder = downloads.store.folder
        Task { showsPicker = await FilesFolderOpener().route(to: folder) == .picker }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct BrowserDownloadLabel<Status: View>: View {
    let name: String
    @ViewBuilder let status: Status
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: "doc")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                Text(name)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) { status }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
    }
}

struct BrowserDownloadsIcon: View {
    let share: Double?
    @ScaledMetric private var diameter: CGFloat = 21

    var body: some View {
        if let share {
            ZStack {
                Circle().stroke(Color(uiColor: .systemFill), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: share)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: diameter * 0.5, weight: .bold))
                    .foregroundStyle(.tint)
            }
            .frame(width: diameter, height: diameter)
            .animation(.default, value: share)
        } else {
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        }
    }
}
