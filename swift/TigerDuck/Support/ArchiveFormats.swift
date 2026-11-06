import Foundation

/// The archives the app opens itself, by the extension their name ends in.
nonisolated enum ArchiveFormats {
    static let extensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz"]

    static func isArchive(name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isArchive(_ url: URL) -> Bool {
        url.isFileURL && isArchive(name: url.lastPathComponent)
    }
}
