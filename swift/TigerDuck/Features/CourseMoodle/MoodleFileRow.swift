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

/// A Moodle file in a list: its type's icon, its name, and its date and size. A tap opens it in
/// the browser, signed in.
struct MoodleFileRow: View {
    let file: MoodleFile
    var now: Date = AppClock.now()

    @Environment(\.openURL) private var openURL

    /// Where a row's text starts, which is where the line between rows starts.
    static let textInset: CGFloat = TigerDuckTheme.Spacing.lg + iconWidth + TigerDuckTheme.Spacing.md
    private static let iconWidth: CGFloat = 28

    var body: some View {
        let kind = MoodleFileKind(mimeType: file.mimeType, fileName: file.name)
        Button {
            guard let url = URL(string: file.url) else { return }
            Task { await openURL(MoodlePage.browserURL(url), fallback: nil) }
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(kind.color)
                    .frame(width: Self.iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(subline)
                        .font(TigerDuckTheme.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Date · size", the date zero-padded and with its year when it is not this year's.
    private var subline: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        guard let modified = file.modified else { return size }
        return "\(modified.moodleDateString(now: now)) · \(size)"
    }
}

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
