#if os(iOS)
import Foundation

struct OpenedArchive: Identifiable, Hashable {
    let url: URL
    let session: URL
    var id: URL { session }
}

@MainActor
final class ArchiveCache {
    static let shared = ArchiveCache(
        root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "ArchivePreview", directoryHint: .isDirectory)
    )

    let root: URL
    private var inUse: Set<String> = []

    init(root: URL) {
        self.root = root
    }

    func open(_ archive: URL) -> OpenedArchive {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !inUse.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
        let name = UUID().uuidString
        inUse.insert(name)
        return OpenedArchive(url: archive, session: root.appending(path: name, directoryHint: .isDirectory))
    }

    func remove(_ session: URL) {
        inUse.remove(session.lastPathComponent)
        try? FileManager.default.removeItem(at: session)
    }
}
#endif
