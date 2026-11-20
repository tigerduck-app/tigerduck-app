import UIKit
import XCTest

/// The class table switcher under the system's own touches, on `UITestFixtureApp`: Ming and Hua in
/// the rotation, nobody in the long-press menu, Lin in Other.
final class ClassTableSwitcherUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-classTableSwitcherFixture"]
        app.launch()
    }

    private var shown: XCUIElement { app.staticTexts["shown"] }

    private func labeled(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func screen(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Opens the menu with a long press, notes where each item is, and closes it again.
    private func menuFrames(_ titles: [String]) -> [String: CGRect] {
        let tab = app.tabBars.buttons.element(boundBy: 1)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.press(forDuration: 1)
        var frames: [String: CGRect] = [:]
        for title in titles {
            let item = app.buttons[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), title)
            frames[title] = item.frame
        }
        screen(app.frame.midX, app.frame.height * 0.15).tap()
        XCTAssertTrue(app.buttons[titles[0]].firstMatch.waitForNonExistence(timeout: 5))
        return frames
    }

    private func pressTabAndSlide(to frame: CGRect, dx: CGFloat = 0) {
        app.tabBars.buttons.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: screen(frame.midX + dx, frame.midY), withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func expectShown(_ label: String) {
        let shows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: shown)
        XCTAssertEqual(XCTWaiter().wait(for: [shows], timeout: 5), .completed, "\(shown.label) instead of \(label)")
    }

    @MainActor
    func testSlidingFromTheTabOntoAnItemAndLiftingRunsIt() throws {
        let add = "Add class table"
        let frames = menuFrames([add, "Hua"])
        XCTAssertEqual(shown.label, "B11300000 0")

        let hua = try XCTUnwrap(frames["Hua"])
        pressTabAndSlide(to: hua, dx: -hua.width / 3)
        expectShown("Hua 0")

        pressTabAndSlide(to: try XCTUnwrap(frames[add]))
        expectShown("Hua 1")
    }

    /// Drags a row by its handle at the trailing end to `y` on the screen.
    private func drag(_ name: String, toY y: CGFloat) {
        let row = labeled(name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), name)
        let handle = screen(row.frame.maxX - 24, row.frame.midY)
        handle.press(forDuration: 0.5, thenDragTo: screen(row.frame.maxX - 24, y), withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(1)
    }

    private func y(_ label: String) -> CGFloat { labeled(label).frame.midY }

    @MainActor
    func testHandlesMovePeopleWithinAndBetweenSections() throws {
        let rotation = "Double-Tap Rotation", longPress = "Long-Press Menu", other = "Other"
        XCTAssertTrue(labeled(longPress).waitForExistence(timeout: 10))
        save("list-before")

        drag("Hua", toY: labeled(longPress).frame.maxY + 30)
        save("list-hua-into-empty")
        XCTAssertGreaterThan(y("Hua"), y(longPress), "Hua into the empty long-press section")
        XCTAssertLessThan(y("Hua"), y(other))

        drag("Lin", toY: y("Ming"))
        save("list-lin-into-rotation")
        XCTAssertLessThan(y("Lin"), y(longPress), "Lin into the rotation")
        XCTAssertGreaterThan(y("Lin"), y("B11300000"))
        XCTAssertGreaterThan(y(other), y("Hua"), "Other left empty")

        drag("Ming", toY: labeled(rotation).frame.minY)
        save("list-ming-above-you")
        XCTAssertGreaterThan(y("Ming"), y("B11300000"), "you stay first")
        XCTAssertLessThan(y("Ming"), y("Lin"))

        drag("Ming", toY: y("Lin") + 8)
        save("list-ming-below-lin")
        XCTAssertGreaterThan(y("Ming"), y("Lin"), "Ming below Lin")
        XCTAssertLessThan(y("Ming"), y(longPress))
    }

    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let out = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".out")
        if FileManager.default.fileExists(atPath: out.path(percentEncoded: false)) {
            try? screenshot.pngRepresentation.write(to: out.appending(path: "ui-\(name)-\(UIDevice.current.systemVersion).png"))
        }
    }
}
