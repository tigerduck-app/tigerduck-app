import Foundation

nonisolated extension FileManager {
    /// The size of a file, or of every file under a folder; what cannot be read counts as nothing.
    func bytes(at url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return values.fileSize ?? 0
        }
        guard let files = enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }
}
