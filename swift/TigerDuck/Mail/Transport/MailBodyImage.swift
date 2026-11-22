#if os(iOS)
import Foundation
import UniformTypeIdentifiers

/// An image in a mail's body, for Quick Look. Only plain raster images: Quick Look draws SVG and
/// HTML with WebKit, JavaScript on, which `MailAttachmentRisk.neverRenderedInApp` keeps out.
nonisolated struct MailBodyImage: Equatable, Sendable {
    var data: Data
    var filename: String

    static let previewableTypes: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .heif, .bmp, .tiff]

    /// No cookies, no stored cache: the sender's server sees the request the page's image made.
    static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return configuration
    }())

    static func previewableType(_ mimeType: String?) -> UTType? {
        guard let mime = MailAttachmentRisk.contentTypeWithoutParameters(mimeType), let type = UTType(mimeType: mime),
              previewableTypes.contains(where: { type.conforms(to: $0) }) else { return nil }
        return type
    }

    /// `source` is the tapped image's address as the page has it: `tdcid:` for a part of the mail,
    /// `data:`, or http(s) once the reader has allowed remote images.
    static func load(
        _ source: String, in detail: MailMessageDetail, allowRemoteImages: Bool, session: URLSession = session
    ) async -> MailBodyImage? {
        if let cid = MailHTMLSanitizer.contentID(ofCIDAddress: source) {
            guard let image = detail.inlineImages?[cid], previewableType(image.mimeType) != nil else { return nil }
            return confirmed(image.data, name: detail.parts.first { $0.contentID == cid }?.filename)
        }
        if let data = MailHTMLSanitizer.dataImageBytes(source) {
            return confirmed(data, name: nil)
        }
        guard allowRemoteImages, let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased()),
              let data = await fetch(url, session: session) else { return nil }
        return confirmed(data, name: url.lastPathComponent == "/" ? nil : url.lastPathComponent)
    }

    /// The bytes decide the type, so markup sent as an image never reaches Quick Look and a PNG
    /// sent as a JPEG opens as the PNG it is.
    private static func confirmed(_ data: Data, name: String?) -> MailBodyImage? {
        guard let type = data.imageType, previewableTypes.contains(where: { type.conforms(to: $0) }) else { return nil }
        return MailBodyImage(data: data, filename: filename(name, type: type))
    }

    /// Reads the body only after a 2xx answer that announces a previewable image of at most
    /// `MailConstants.maxInlineImageBytes`, and stops past that many whatever was announced.
    private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        let limit = MailConstants.maxInlineImageBytes
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              previewableType(response.mimeType) != nil, response.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : limit)
        do {
            for try await byte in bytes {
                guard data.count < limit else { return nil }
                data.append(byte)
            }
        } catch {
            return nil
        }
        return data
    }

    /// The name the mail gives the image, with the extension of the type its bytes are.
    static func filename(_ name: String?, type: UTType) -> String {
        let stem = name.map { MailAttachmentRisk.displayFilename(($0 as NSString).deletingPathExtension) }
        let base = stem?.mailNonEmpty ?? "image"
        return type.preferredFilenameExtension.map { "\(base).\($0)" } ?? base
    }
}
#endif
