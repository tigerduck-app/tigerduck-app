#if os(iOS)
import Foundation

nonisolated enum ArchiveNode: Hashable, Identifiable, Sendable {
    case folder(path: String, name: String)
    case file(ArchiveItem)

    var id: String {
        switch self {
        case .folder(let path, _): "d/\(path)"
        case .file(let item): "f/\(item.index)"
        }
    }

    var name: String {
        switch self {
        case .folder(_, let name): name
        case .file(let item): item.name
        }
    }
}

nonisolated struct ArchiveTree: Sendable {
    private var folders: [String: [String: ArchiveNode]] = ["": [:]]
    private var files: [String: [ArchiveNode]] = [:]
    private(set) var placed = 0
    private(set) var truncated = false

    init(_ items: [ArchiveItem], maxFolders: Int = .max) throws {
        for item in items {
            try Task.checkCancellation()
            let parts = item.path.split(separator: "/").map(String.init)
            var parent = ""
            var added: [(parent: String, path: String, name: String)] = []
            for name in parts.prefix(item.isDirectory ? parts.count : parts.count - 1) {
                let path = parent.isEmpty ? name : parent + "/" + name
                if folders[path] == nil { added.append((parent, path, name)) }
                parent = path
            }
            guard folders.count - 1 + added.count <= maxFolders else {
                truncated = true
                return
            }
            for folder in added {
                folders[folder.parent, default: [:]][folder.path] = .folder(path: folder.path, name: folder.name)
                folders[folder.path] = [:]
            }
            if !item.isDirectory { files[parent, default: []].append(.file(item)) }
            placed += 1
        }
    }

    func children(of folder: String) -> [ArchiveNode] {
        let byName: (ArchiveNode, ArchiveNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (folders[folder]?.values.sorted(by: byName) ?? []) + (files[folder]?.sorted(by: byName) ?? [])
    }

    func count(of folder: String) -> Int {
        (folders[folder]?.count ?? 0) + (files[folder]?.count ?? 0)
    }
}
#endif
