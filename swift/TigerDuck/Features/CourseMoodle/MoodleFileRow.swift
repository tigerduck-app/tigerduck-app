import SwiftUI

/// What a Moodle file holds, for its icon: by MIME type, else by extension.
nonisolated enum MoodleFileKind: Equatable {
    case pdf, document, presentation, spreadsheet, image, video, audio, archive, text, other

    init(mimeType: String?, fileName: String) {
        if let kind = Self(mimeType: mimeType?.lowercased() ?? "") {
            self = kind
        } else {
            self = Self(extension: (fileName as NSString).pathExtension.lowercased()) ?? .other
        }
    }

    private init?(mimeType: String) {
        switch mimeType {
        case "": return nil
        case "application/pdf": self = .pdf
        case _ where mimeType.contains("presentation") || mimeType.contains("powerpoint"): self = .presentation
        case _ where mimeType.contains("spreadsheet") || mimeType.contains("excel") || mimeType == "text/csv":
            self = .spreadsheet
        case _ where mimeType.contains("wordprocessing") || mimeType == "application/msword": self = .document
        case _ where mimeType.hasPrefix("image/"): self = .image
        case _ where mimeType.hasPrefix("video/"): self = .video
        case _ where mimeType.hasPrefix("audio/"): self = .audio
        case "application/zip", "application/x-zip-compressed", "application/x-7z-compressed",
             "application/x-rar-compressed", "application/vnd.rar", "application/gzip", "application/x-tar":
            self = .archive
        case "text/plain": self = .text
        default: return nil
        }
    }

    private init?(extension ext: String) {
        switch ext {
        case "pdf": self = .pdf
        case "doc", "docx", "odt", "rtf", "pages": self = .document
        case "ppt", "pptx", "odp", "key": self = .presentation
        case "xls", "xlsx", "ods", "csv", "numbers": self = .spreadsheet
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff", "svg": self = .image
        case "mp4", "mov", "m4v", "avi", "mkv", "webm": self = .video
        case "mp3", "m4a", "wav", "aac", "flac", "ogg": self = .audio
        case "zip", "rar", "7z", "gz", "tar", "tgz": self = .archive
        case "txt", "md": self = .text
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .document: "doc.text.fill"
        case .presentation: "play.rectangle.on.rectangle.fill"
        case .spreadsheet: "tablecells.fill"
        case .image: "photo.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .archive: "doc.zipper"
        case .text: "doc.plaintext.fill"
        case .other: "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .pdf: .red
        case .document: .blue
        case .presentation: .orange
        case .spreadsheet: .green
        case .image: .purple
        case .video, .audio: .pink
        case .archive, .text, .other: .gray
        }
    }
}

/// One context menu serves the long press, the iPad's secondary click and the Mac's right click.
struct MoodleFileRow: View {
    let title: String
    let file: MoodleFile
    let state: MoodleDownloadState
    var indent: CGFloat = 0
    var now: Date = AppClock.now()
    let tap: () -> Void
    let share: () -> Void
    let openInMoodle: () -> Void

    /// The line between rows starts under the text, not under the icon.
    static let textInset: CGFloat = TigerDuckTheme.Spacing.lg + iconWidth + TigerDuckTheme.Spacing.md
    static let folderIndent: CGFloat = 28
    fileprivate static let iconWidth: CGFloat = 28

    var body: some View {
        let kind = MoodleFileKind(mimeType: file.mimeType, fileName: file.name)
        Button(action: tap) {
            MoodleListRowLayout(indent: indent) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(kind.color)
            } text: {
                Text(title)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(subline)
                    .font(TigerDuckTheme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
            } trailing: {
                MoodleDownloadMark(state: state)
            }
        }
        .buttonStyle(.plain)
        .moodleRowHover()
        .contextMenu {
            MoodleRowMenu(share: share, openInMoodle: openInMoodle)
        }
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityActions {
            if case .downloading = state {
                Button(String(localized: "action_cancel"), action: tap)
            }
        }
        #if os(macOS)
        .modifier(MoodleFileDrag(url: downloadedURL))
        #endif
    }

    /// "Date · size", the date zero-padded and with its year when it is not this year's.
    private var subline: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        guard let modified = file.modified else { return size }
        return "\(modified.moodleDateString(now: now)) · \(size)"
    }

    private var accessibilityValue: String {
        switch state {
        case .downloading(let progress): "\(subline), \(progress.formatted(.percent.precision(.fractionLength(0))))"
        case .failed(let message): "\(subline), \(message)"
        case .notDownloaded, .downloaded: subline
        }
    }

    private var downloadedURL: URL? {
        if case .downloaded(let url) = state { url } else { nil }
    }
}

struct MoodleLinkRow: View {
    let title: String
    let url: URL
    let open: () -> Void
    let share: () -> Void
    let openInMoodle: () -> Void

    var body: some View {
        Button(action: open) {
            MoodleListRowLayout(indent: 0) {
                Image(systemName: "link")
                    .font(.system(size: 22))
                    .foregroundStyle(.teal)
            } text: {
                Text(title)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(Self.site(of: url))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            } trailing: {
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .moodleRowHover()
        .contextMenu {
            MoodleRowMenu(share: share, openInMoodle: openInMoodle)
        }
        .accessibilityLabel(title)
        .accessibilityValue(Self.site(of: url))
    }

    /// The host without its `www.`, which says where the link goes in fewer characters.
    static func site(of url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Not a button: a folder only heads the files listed under it.
struct MoodleFolderRow: View {
    let name: String
    let fileCount: Int

    var body: some View {
        MoodleListRowLayout(indent: 0) {
            Image(systemName: "folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.textSecondary)
        } text: {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
        } trailing: {
            Text(fileCount, format: .number)
                .font(TigerDuckTheme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(fileCount.formatted())
    }
}

/// The trailing mark keeps its width however the text wraps, so the marks line up down a card.
private struct MoodleListRowLayout<Icon: View, Lines: View, Trailing: View>: View {
    let indent: CGFloat
    @ViewBuilder let icon: Icon
    @ViewBuilder let text: Lines
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            icon
                .frame(width: MoodleFileRow.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) { text }
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
        }
        .padding(.leading, TigerDuckTheme.Spacing.lg + indent)
        .padding(.trailing, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A downloaded file shows no mark, as in the Files app.
private struct MoodleDownloadMark: View {
    let state: MoodleDownloadState

    var body: some View {
        switch state {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 22))
                .foregroundStyle(Color.textSecondary)
        case .downloading(let progress):
            ZStack {
                Circle()
                    .stroke(Color.textSecondary.opacity(0.3), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "stop.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.tint)
            }
            .frame(width: 20, height: 20)
        case .downloaded:
            Color.clear
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.schoolOrange)
        }
    }
}

private struct MoodleRowMenu: View {
    let share: () -> Void
    let openInMoodle: () -> Void

    var body: some View {
        Button(action: share) {
            Label(String(localized: "school_mail_attachment_share"), systemImage: "square.and.arrow.up")
        }
        Button(action: openInMoodle) {
            Label(String(localized: "action_open_in_moodle"), systemImage: "arrow.up.right.square")
        }
    }
}

private extension View {
    func moodleRowHover() -> some View {
        #if os(iOS)
        hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Only a copy on the device can be handed to the Finder.
private struct MoodleFileDrag: ViewModifier {
    let url: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url {
            content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            content
        }
    }
}
#endif

extension MoodlePage {
    /// A file link in the browser: Moodle's web service path wants a token, which the browser
    /// does not have, and the same file under the site's own path takes the signed-in session.
    static func browserURL(_ url: URL) -> URL {
        let prefix = "/webservice/pluginfile.php/"
        guard MoodleAutologinService.isMoodlePage(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasPrefix(prefix) else { return url }
        components.percentEncodedPath = "/pluginfile.php/" + components.percentEncodedPath.dropFirst(prefix.count)
        let items = components.queryItems?.filter { $0.name != "token" }
        components.queryItems = items?.isEmpty == true ? nil : items
        return components.url ?? url
    }
}
