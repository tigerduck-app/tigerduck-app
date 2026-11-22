#if os(iOS)
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import TigerDuck

struct MailBodyImageTests {
    static let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
    static let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).jpegData(withCompressionQuality: 0.8) { _ in }
    static let svgMarkup = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#.utf8)
    static let htmlMarkup = Data("<html><body><script>alert(1)</script></body></html>".utf8)

    static func detail(images: [String: MailInlineImage], parts: [MailBodyPart] = []) throws -> MailMessageDetail {
        var detail = try #require(FakeMailClient.message(uid: 5, html: "<p>x</p>").detail)
        detail.inlineImages = images
        detail.parts = parts
        return detail
    }

    static func inlinePart(_ cid: String, filename: String?) -> MailBodyPart {
        MailBodyPart(section: "2", contentType: "image/png", charset: nil, transferEncoding: "base64",
                     filename: filename, contentID: cid, size: 8, isAttachment: false)
    }

    static func dataAddress(_ data: Data, type: String = "image/png") -> String {
        "data:\(type);base64,\(data.base64EncodedString())"
    }

    static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    static func remote(_ name: String, answer: SettingsAPIStub.StubResponse) -> String {
        let url = SettingsAPIStub.uniqueBaseURL().appending(path: name)
        SettingsAPIStub.enqueue(answer, for: url)
        return url.absoluteString
    }

    @Test func anInlineImageComesFromTheMailUnderItsPartsName() async throws {
        let detail = try Self.detail(images: ["image001.png@01DA": MailInlineImage(mimeType: "image/png", data: Self.png)],
                                     parts: [Self.inlinePart("image001.png@01DA", filename: "教室配置圖.png")])
        let image = await MailBodyImage.load("tdcid:image001.png@01DA", in: detail, allowRemoteImages: false)
        #expect(image == MailBodyImage(data: Self.png, filename: "教室配置圖.png"))
    }

    @Test func aPercentEncodedContentIDFindsItsImage() async throws {
        let detail = try Self.detail(images: ["a b@x": MailInlineImage(mimeType: "image/jpeg; name=a.jpg", data: Self.jpeg)])
        let image = await MailBodyImage.load("tdcid:a%20b@x", in: detail, allowRemoteImages: false)
        #expect(image == MailBodyImage(data: Self.jpeg, filename: "image.jpeg"))
    }

    @Test(arguments: ["image/svg+xml", "text/html", "application/octet-stream", "image/x-icon-unknown"])
    func anImageQuickLookWouldDrawWithWebKitOrCannotReadGetsNoPreview(type: String) async throws {
        let detail = try Self.detail(images: ["logo": MailInlineImage(mimeType: type, data: Self.png)])
        #expect(await MailBodyImage.load("tdcid:logo", in: detail, allowRemoteImages: false) == nil)
    }

    @Test(arguments: [svgMarkup, htmlMarkup])
    func markupSentAsAPNGGetsNoPreview(markup: Data) async throws {
        let detail = try Self.detail(images: ["logo": MailInlineImage(mimeType: "image/png", data: markup)])
        #expect(await MailBodyImage.load("tdcid:logo", in: detail, allowRemoteImages: false) == nil)
        #expect(await MailBodyImage.load(Self.dataAddress(markup), in: detail, allowRemoteImages: false) == nil)
    }

    @Test func aPNGSentAsAJPEGPreviewsAsThePNGItIs() async throws {
        let detail = try Self.detail(images: ["photo": MailInlineImage(mimeType: "image/jpeg", data: Self.png)],
                                     parts: [Self.inlinePart("photo", filename: "photo.jpg")])
        let image = await MailBodyImage.load("tdcid:photo", in: detail, allowRemoteImages: false)
        #expect(image == MailBodyImage(data: Self.png, filename: "photo.png"))
    }

    @Test func anUnknownContentIDGetsNoPreview() async throws {
        let detail = try Self.detail(images: [:])
        #expect(await MailBodyImage.load("tdcid:missing", in: detail, allowRemoteImages: false) == nil)
    }

    @Test func aDataImageIsDecodedInTheApp() async throws {
        let detail = try Self.detail(images: [:])
        let image = await MailBodyImage.load(Self.dataAddress(Self.png), in: detail, allowRemoteImages: false)
        #expect(image == MailBodyImage(data: Self.png, filename: "image.png"))
        let escaped = Self.dataAddress(Self.png).replacingOccurrences(of: ",iVBOR", with: ",%69VBOR")
        #expect(escaped.contains("%69"))
        #expect(await MailBodyImage.load(escaped, in: detail, allowRemoteImages: false)
                == MailBodyImage(data: Self.png, filename: "image.png"))
        let svg = Self.dataAddress(Self.svgMarkup, type: "image/svg+xml")
        #expect(await MailBodyImage.load(svg, in: detail, allowRemoteImages: false) == nil)
    }

    @Test(arguments: ["https://tracker.example/p.png", "http://tracker.example/p.png", "file:///etc/hosts", "javascript:alert(1)"])
    func aRemoteImageIsFetchedOnlyOnceTheReaderAllowedThem(source: String) async throws {
        let detail = try Self.detail(images: [:])
        #expect(await MailBodyImage.load(source, in: detail, allowRemoteImages: false) == nil)
    }

    @Test func onlyAWebAddressIsFetchedWhenRemoteImagesAreAllowed() async throws {
        let detail = try Self.detail(images: [:])
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Self.png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await MailBodyImage.load(file.absoluteString, in: detail, allowRemoteImages: true) == nil)
        #expect(await MailBodyImage.load("javascript:alert(1)", in: detail, allowRemoteImages: true) == nil)
    }

    @Test func aRemoteImageIsReadUpToTheInlineImageLimit() async throws {
        let detail = try Self.detail(images: [:])
        let fits = Self.png + Data(count: MailConstants.maxInlineImageBytes - Self.png.count)
        let image = { (body: Data) in
            SettingsAPIStub.StubResponse(statusCode: 200, body: body, headerFields: ["Content-Type": "image/png"])
        }
        let source = Self.remote("課表.png", answer: image(fits))
        #expect(await MailBodyImage.load(source, in: detail, allowRemoteImages: true, session: Self.stubSession())
                == MailBodyImage(data: fits, filename: "課表.png"))
        let over = Self.remote("p.png", answer: image(fits + [0]))
        #expect(await MailBodyImage.load(over, in: detail, allowRemoteImages: true, session: Self.stubSession()) == nil)
    }

    @MainActor
    final class Arrival {
        var answered = false
    }

    @MainActor
    @Test(arguments: zip([404, 200, 200], [
        ["Content-Type": "image/png"],
        ["Content-Type": "text/html"],
        ["Content-Type": "image/png", "Content-Length": "\(MailConstants.maxInlineImageBytes + 1)"],
    ]))
    func aBodyIsNotReadAfterAnErrorAnotherTypeOrALengthPastTheLimit(status: Int, headers: [String: String]) async throws {
        let detail = try Self.detail(images: [:])
        let body = SettingsAPIStub.ReplyGate()
        defer { body.open() }
        let source = Self.remote("p.png", answer: SettingsAPIStub.StubResponse(
            statusCode: status, body: Self.png + Data(count: 4 * SettingsAPIStub.sniffedBytes), headerFields: headers, bodyGate: body
        ))
        let session = Self.stubSession()
        let arrival = Arrival()
        let loading = Task {
            defer { arrival.answered = true }
            return await MailBodyImage.load(source, in: detail, allowRemoteImages: true, session: session)
        }
        try await waitUntil(timeout: .seconds(10)) { arrival.answered }
        body.open()
        #expect(await loading.value == nil)
    }

    @Test func theFileTakesTheExtensionOfItsType() {
        #expect(MailBodyImage.filename("photo.JPG", type: .png) == "photo.png")
        #expect(MailBodyImage.filename(nil, type: .gif) == "image.gif")
        #expect(MailBodyImage.filename(" ", type: .webP) == "image.webp")
        #expect(MailBodyImage.filename("a/b.png", type: .png) == "a/b.png")
    }
}
#endif
