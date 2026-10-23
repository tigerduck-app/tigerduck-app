import Foundation
#if os(iOS)
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
#endif
import Testing
@testable import TigerDuck

@MainActor
struct MoodleOwnProfileTests {
    private nonisolated static let ownId = 42

    private nonisolated static func member(_ id: Int, _ fullName: String) -> MoodleMember {
        MoodleMember(id: id, fullName: fullName, idNumber: nil, email: nil, groups: [],
                     roles: [MoodleMember.Role(shortName: "student", name: "", sortOrder: 0)], pictureURL: nil,
                     description: "", interests: [], fields: [])
    }

    private final class Site: @unchecked Sendable {
        private let lock = NSLock()
        private var _functions: Set<String>
        private var _uploads: [Data] = []
        private var _memberCalls = 0

        init(functions: Set<String>) { _functions = functions }

        var uploads: [Data] { lock.withLock { _uploads } }
        var memberCalls: Int { lock.withLock { _memberCalls } }

        var api: MoodleCourseAPI {
            var api = MoodleCourseAPI(
                functions: { self.lock.withLock { self._functions } },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                members: { _ in
                    self.lock.withLock { self._memberCalls += 1 }
                    return MoodleMemberList(ownId: MoodleOwnProfileTests.ownId,
                                            members: [MoodleOwnProfileTests.member(MoodleOwnProfileTests.ownId, "Tiger Duck")])
                }
            )
            api.updatePicture = { jpeg in self.lock.withLock { self._uploads.append(jpeg) } }
            return api
        }
    }

    private static func store(_ site: Site, root: URL) -> MoodleCourseStore {
        let cache = DataCache(cacheDir: root.appendingPathComponent("cache", isDirectory: true),
                              persistentDir: root.appendingPathComponent("persistent", isDirectory: true))
        return MoodleCourseStore(
            courseId: 1, termCourseIds: [1],
            context: MoodleCacheContext(account: "B11399001", cache: cache, isCurrent: { true }, now: { Date() }),
            api: site.api
        )
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MoodleOwnProfileTests-\(UUID().uuidString)")
    }

    @Test("the picture can change only on a site that lists core_user_update_picture")
    func pictureChangeFollowsTheSite() async {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await Self.store(Site(functions: [MoodleProfilePictureService.updateFunction]), root: root).allowsPictureChange())
        #expect(!(await Self.store(Site(functions: [MoodleCourseMembersService.membersFunction]), root: root).allowsPictureChange()))
    }

    @Test("a new picture is uploaded, then the members are fetched again for its address")
    func aNewPictureRefreshesTheMembers() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let site = Site(functions: [MoodleProfilePictureService.updateFunction, MoodleCourseMembersService.membersFunction])
        let store = Self.store(site, root: root)

        try await store.updatePicture(Data([1, 2, 3]))

        #expect(site.uploads == [Data([1, 2, 3])])
        #expect(site.memberCalls == 1)
        #expect(store.members.value?.ownId == Self.ownId)
    }

    #if os(iOS)
    @Test("the crop is the square under the circle, kept covered by the photo")
    func cropMath() {
        let image = CGSize(width: 400, height: 300)
        #expect(MoodlePictureCropView.cropRect(imageSize: image, diameter: 300, scale: 1, offset: .zero)
            == CGRect(x: 50, y: 0, width: 300, height: 300))
        #expect(MoodlePictureCropView.cropRect(imageSize: image, diameter: 150, scale: 2, offset: CGSize(width: 15, height: -10))
            == CGRect(x: 110, y: 85, width: 150, height: 150))
        #expect(MoodlePictureCropView.clampedOffset(CGSize(width: 80, height: 20), imageSize: image, diameter: 300, scale: 1)
            == CGSize(width: 50, height: 0))
        #expect(MoodlePictureCropView.clampedScale(0.5) == 1)
        #expect(MoodlePictureCropView.clampedScale(9) == MoodlePictureCropView.maxScale)
    }

    @Test("the uploaded picture is a 512 px square JPEG")
    func cropOutput() throws {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let jpeg = try #require(MoodlePictureCropView.jpeg(photo, cropping: CGRect(x: 5, y: 0, width: 30, height: 30)))
        let decoded = try #require(UIImage(data: jpeg)?.cgImage)
        #expect(decoded.width == 512)
        #expect(decoded.height == 512)
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
    }

    @Test("a transparent picture uploads on white, not black")
    func transparentPartsTurnWhite() throws {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format).image { _ in }
        let jpeg = try #require(MoodlePictureCropView.jpeg(clear, cropping: CGRect(x: 0, y: 0, width: 10, height: 10)))
        let decoded = try #require(UIImage(data: jpeg)?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(decoded, in: CGRect(x: -256, y: -256, width: 512, height: 512))
        #expect(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240, "\(pixel)")
    }

    @Test("a picked photo is decoded at 2048 px at most, the right way up")
    func aPickedPhotoIsDownsampled() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let image = try #require(big.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        // Orientation 6: the camera held upright, so the stored landscape pixels show as portrait.
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let picked = try #require(MoodlePictureCropView.downsampled(data as Data))
        #expect(picked.height == MoodlePictureCropView.maxPickedPixels)
        #expect(abs(picked.width - 1365) <= 1)
        #expect(MoodlePictureCropView.downsampled(Data("not an image".utf8)) == nil)
    }

    @Test("a second tap on Done uploads nothing more")
    func doneUploadsOnce() async throws {
        try await withAccessibilityAutomation {
            var uploads = 0
            let photo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { _ in }
            let window = try show(MoodlePictureCropView(image: photo, onCancel: {}, onDone: { _ in uploads += 1 }))
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController?.view)
            let done = String(localized: "action_done")
            try await waitUntil { accessibilityElement(labeled: done, in: root) != nil }

            _ = accessibilityElement(labeled: done, in: root)?.accessibilityActivate()
            _ = accessibilityElement(labeled: done, in: root)?.accessibilityActivate()
            try await waitUntil { accessibilityElement(labeled: done, in: root)?.accessibilityTraits.contains(.notEnabled) == true }
            _ = accessibilityElement(labeled: done, in: root)?.accessibilityActivate()

            #expect(uploads == 1)
        }
    }

    private func show(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        return window
    }

    @Test("the signed-in student's row reads their name, then Me")
    func theOwnRowSaysMe() async throws {
        try await withAccessibilityAutomation {
            let me = String(localized: "course_member_me")
            for (isMe, label) in [(true, "Tiger Duck, \(me)"), (false, "Tiger Duck")] {
                let window = try show(MoodleMemberRow(member: Self.member(Self.ownId, "Tiger Duck"), picture: nil, isMe: isMe))
                defer { window.isHidden = true }
                let root = try #require(window.rootViewController?.view)
                try await waitUntil { accessibilityElement(labeled: label, in: root) != nil }
            }
        }
    }

    @Test("the camera button shows only where the picture can change, and runs the change")
    func theCameraButtonFollowsTheSite() async throws {
        try await withAccessibilityAutomation {
            let label = String(localized: "course_member_change_picture")
            var asked = 0
            for canChange in [true, false] {
                let window = try show(MoodleMemberProfile(
                    member: Self.member(Self.ownId, "Tiger Duck"), picture: nil, policy: VisualStylePolicy(preset: .default),
                    writeTo: { _ in }, openPicture: {}, changePicture: canChange ? { asked += 1 } : nil
                ))
                defer { window.isHidden = true }
                let root = try #require(window.rootViewController?.view)
                try await waitUntil { accessibilityElement(labeled: "Tiger Duck", in: root) != nil }
                let button = accessibilityElement(labeled: label, in: root)
                guard canChange else {
                    #expect(button == nil)
                    continue
                }
                #expect(try #require(button).accessibilityActivate())
                try await waitUntil { asked == 1 }
            }
        }
    }
    #endif
}
