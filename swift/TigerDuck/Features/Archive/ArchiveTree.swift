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

    init(_ items: [ArchiveItem]) {
        for item in items {
            let parts = item.path.split(separator: "/").map(String.init)
            let depth = item.isDirectory ? parts.count : parts.count - 1
            for level in 0..<depth {
                let parent = parts[..<level].joined(separator: "/")
                let path = parts[...level].joined(separator: "/")
                folders[parent, default: [:]][path] = .folder(path: path, name: parts[level])
                if folders[path] == nil { folders[path] = [:] }
            }
            if !item.isDirectory {
                files[parts.dropLast().joined(separator: "/"), default: []].append(.file(item))
            }
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
