import XCTest
import SwiftUI
@testable import TigerDuckWatchWidget

final class NextClassWidgetSnapshotTests: XCTestCase {

    private func sampleEntry(now: Bool = true, next: Bool = true) -> NextClassEntry {
        NextClassEntry(
            date: Date(),
            current: now ? sampleCourse(name: "現在") : nil,
            next: next ? sampleCourse(name: "下一堂") : nil,
            accentHex: "#FF8800",
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
}
