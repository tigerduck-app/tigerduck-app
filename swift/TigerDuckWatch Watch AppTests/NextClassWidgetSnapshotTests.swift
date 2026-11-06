import XCTest
import SwiftUI
import ImageIO
@testable import TigerDuckWatch_Watch_App
import TigerDuckCore

final class NextClassWidgetSnapshotTests: XCTestCase {

    private func sampleEntry(now: Bool = true, next: Bool = true) -> NextClassEntry {
        NextClassEntry(
            date: Date(),
            current: now ? sampleCourse(name: "現在") : nil,
            next: next ? sampleCourse(name: "下一堂") : nil,
            nextDay: .today,
            currentSpan: nil,
            accentHex: "#FF8800",
            languageTag: nil,
            relevance: nil
        )
    }

    private func sampleCourse(name: String) -> WatchCourse {
        WatchCourse(
            id: "x-1-3", courseNo: "X",
            name: name, teacher: "T",
            classroom: "TR-313", colorHex: "#FF8800",
            weekday: 1, startHHmm: "10:20", endHHmm: "11:10",
            periodLabel: "3-4"
        )
    }

    @MainActor
    private func render<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: 200, height: 80))
        return renderer.cgImage
    }

    @MainActor
    func test_rectangularRendersNonNil() {
        XCTAssertNotNil(render(RectangularView(entry: sampleEntry())))
    }

    @MainActor
    func test_circularRendersNonNil() {
        XCTAssertNotNil(render(CircularView(entry: sampleEntry())))
    }

    @MainActor
    func test_inlineRendersNonNil() {
        XCTAssertNotNil(render(InlineView(entry: sampleEntry())))
    }

    @MainActor
    func test_cornerRendersNonNil() {
        XCTAssertNotNil(render(CornerView(entry: sampleEntry())))
    }

    @MainActor
    func test_emptyState_rendersWithoutCrashing() {
        XCTAssertNotNil(render(RectangularView(entry: sampleEntry(now: false, next: false))))
    }

    private static let pictureLanguages = [
        (tag: "zh-Hant", now: "資料結構與演算法專題研究與實作", next: "計算機網路概論"),
        (tag: "en", now: "Advanced Topics in Data Structures and Algorithms", next: "Introduction to Computer Networks"),
    ]

    private func pictureCourse(name: String, room: String, color: String, start: String, end: String) -> WatchCourse {
        WatchCourse(
            id: name, courseNo: "X", name: name, teacher: "", classroom: room, colorHex: color,
            weekday: 1, startHHmm: start, endHHmm: end, periodLabel: "3-4"
        )
    }

    @MainActor
    func test_picturesOfThePageAndEachFamily_withALongNameAndRoom() throws {
        let out = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".out")
        let outFolderExists = FileManager.default.fileExists(atPath: out.path(percentEncoded: false))
        let folder = out.appending(path: "watch-complications")
        if outFolderExists { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let span = Date().addingTimeInterval(-40 * 60)...Date().addingTimeInterval(70 * 60)

        for language in Self.pictureLanguages {
            let now = pictureCourse(name: language.now, room: "IB-1005 階梯教室", color: "#4ECDC4", start: "10:20", end: "12:10")
            let next = pictureCourse(name: language.next, room: "TR-412", color: "#F5A623", start: "13:20", end: "14:10")
            let words = WatchLanguage(tag: language.tag)
            let during = NextClassEntry(
                date: Date(), current: now, next: next, nextDay: .today, currentSpan: span,
                accentHex: "#FF8800", languageTag: language.tag, relevance: nil
            )
            let before = NextClassEntry(
                date: Date(), current: nil, next: next, nextDay: .tomorrow, currentSpan: nil,
                accentHex: "#FF8800", languageTag: language.tag, relevance: nil
            )
            let farRoom = pictureCourse(name: language.next, room: "IB-1005 階梯教室", color: "#F5A623", start: "09:10", end: "12:00")
            let beforeFarRoom = NextClassEntry(
                date: Date(), current: nil, next: farRoom, nextDay: .tomorrow, currentSpan: nil,
                accentHex: "#FF8800", languageTag: language.tag, relevance: nil
            )
            let threeHours = Date().addingTimeInterval(-60 * 60)...Date().addingTimeInterval(120 * 60)
            let threeHourClass = pictureCourse(name: language.now, room: "TR-412", color: "#4ECDC4", start: "09:10", end: "12:10")
            let longClass = NextClassEntry(
                date: Date(), current: threeHourClass, next: nil, nextDay: .today, currentSpan: threeHours,
                accentHex: "#FF8800", languageTag: language.tag, relevance: nil
            )
            let policy = WatchVisualStylePolicy(preset: .default)
            func page(width: CGFloat) -> some View {
                VStack(spacing: 12) {
                    ClassCard(title: words.string("watch_now"), course: now, span: span, policy: policy, language: words)
                    ClassCard(
                        title: NextClassResolver.Day.today.headline(in: words), course: next, span: nil, policy: policy,
                        language: words
                    )
                }
                .padding(.horizontal, 8)
                .frame(width: width, alignment: .top)
            }
            let threeHourPage = ClassCard(
                title: words.string("watch_now"), course: threeHourClass, span: threeHours, policy: policy, language: words
            )
            .padding(.horizontal, 8)

            let pictures: [(name: String, view: AnyView, size: CGSize?)] = [
                ("page", AnyView(page(width: 208)), CGSize(width: 208, height: 248)),
                ("page-41mm", AnyView(page(width: 176)), CGSize(width: 176, height: 215)),
                ("page-45mm", AnyView(page(width: 198)), CGSize(width: 198, height: 242)),
                ("page-49mm", AnyView(page(width: 205)), CGSize(width: 205, height: 251)),
                ("page-3h-41mm", AnyView(threeHourPage), CGSize(width: 176, height: 120)),
                ("page-largest-text", AnyView(page(width: 208).dynamicTypeSize(.accessibility3)), nil),
                ("rectangular", AnyView(RectangularView(entry: during)), CGSize(width: 193, height: 82)),
                ("rectangular-next", AnyView(RectangularView(entry: before)), CGSize(width: 193, height: 82)),
                ("rectangular-next-long-room", AnyView(RectangularView(entry: beforeFarRoom)), CGSize(width: 193, height: 82)),
                ("rectangular-3h", AnyView(RectangularView(entry: longClass)), CGSize(width: 193, height: 82)),
                ("rectangular-3h-41mm", AnyView(RectangularView(entry: longClass)), CGSize(width: 171.5, height: 73)),
                ("circular", AnyView(CircularView(entry: during)), CGSize(width: 50, height: 50)),
                ("corner", AnyView(CornerView(entry: during)), CGSize(width: 38, height: 38)),
                ("inline", AnyView(InlineView(entry: during)), CGSize(width: 180, height: 20)),
                ("inline-next", AnyView(InlineView(entry: before)), CGSize(width: 180, height: 20)),
            ]
            for picture in pictures {
                let image = try XCTUnwrap(
                    renderOnWatch(picture.view, width: picture.size?.width ?? 208, height: picture.size?.height, locale: words.locale),
                    picture.name
                )
                guard outFolderExists else { continue }
                let file = folder.appending(path: "\(picture.name)-\(language.tag).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }
}
