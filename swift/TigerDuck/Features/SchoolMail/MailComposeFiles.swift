#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum MailComposeFiles {
    static func read(_ url: URL) async -> (data: Data, mimeType: String, filename: String)? {
        await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = readBounded(url) else { return nil as (data: Data, mimeType: String, filename: String)? }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return (data, mimeType, url.lastPathComponent)
        }.value
    }

    static func loadPhotos(_ items: [PhotosPickerItem], add: (String, String, Data) -> Void) async -> Bool {
        var anyFailed = false
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                anyFailed = true
                continue
            }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            add("IMG_\(index + 1).\(ext)", type?.preferredMIMEType ?? "image/jpeg", data)
        }
        return anyFailed
    }

    private nonisolated static func readBounded(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return readBounded(read: handle.read(upToCount:))
    }

    nonisolated static func readBounded(read: (Int) throws -> Data?) -> Data? {
        var data = Data()
        do {
            while let chunk = try read(1024 * 1024), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= MailConstants.maxEncodedMessageBytes else { return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}
#endif
