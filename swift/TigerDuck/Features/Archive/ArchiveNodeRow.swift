#if os(iOS)
import SwiftUI

struct ArchiveNodeRow: View {
    let node: ArchiveNode
    let tree: ArchiveTree
    let model: ArchiveBrowserModel
    var now: Date = AppClock.now()

    var body: some View {
        switch node {
        case .folder(let path, let name):
            let count = tree.count(of: path)
            NavigationLink(value: ArchiveFolder(path: path, name: name)) {
                MoodleListRowLayout(indent: 0) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.blue)
                } text: {
                    title(name)
                } trailing: {
                    HStack(spacing: TigerDuckTheme.Spacing.sm) {
                        Text(count, format: .number)
                            .font(TigerDuckTheme.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.textSecondary)
                    }
                    .frame(minWidth: 30, alignment: .trailing)
                }
            }
            .buttonStyle(.plain)
            .moodleRowHover()
            .accessibilityLabel(name)
            .accessibilityValue("\(String(localized: "file_viewer_archive_folder")), \(count.formatted())")
        case .file(let item):
            Button { model.open(item) } label: {
                MoodleListRowLayout(indent: 0) {
                    icon(item)
                } text: {
                    title(item.name)
                    if !subline(item).isEmpty {
                        Text(subline(item))
                            .font(TigerDuckTheme.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.textSecondary)
                    }
                } trailing: {
                    if model.opening == item.index { ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .moodleRowHover()
            .accessibilityLabel(item.name)
            .accessibilityValue([subline(item), item.problem?.reason ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        }
    }

    private func title(_ name: String) -> some View {
        Text(name)
            .font(TigerDuckTheme.Typography.body)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private func icon(_ item: ArchiveItem) -> some View {
        switch item.problem {
        case .password:
            Image(systemName: "lock.fill").font(.system(size: 20)).foregroundStyle(Color.textSecondary)
        case .link:
            Image(systemName: "link").font(.system(size: 20)).foregroundStyle(Color.textSecondary)
        default:
            let kind = MoodleFileKind(mimeType: nil, fileName: item.name)
            Image(systemName: kind.symbol).font(.system(size: 22)).foregroundStyle(kind.color)
        }
    }

    private func subline(_ item: ArchiveItem) -> String {
        let size = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return [item.modified?.moodleDateString(now: now), size].compactMap(\.self).joined(separator: " · ")
    }
}
#endif
