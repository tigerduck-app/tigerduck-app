import XCTest

/// The Watch's App Store screenshots of the demo account the paired phone signed in to: today's
/// classes, the next class and the library QR. `tools/app_store_screenshots.py` runs it and passes
/// `SCREENSHOTS_DIR`; without it the test skips.
final class WatchScreenshotTests: XCTestCase {
    @MainActor
    func testScreens() throws {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"] else {
            throw XCTSkip("SCREENSHOTS_DIR is not set")
        }
        let output = URL(filePath: directory, directoryHint: .isDirectory)
        continueAfterFailure = false
        let app = XCUIApplication()
        // The debug build's switch: a UI test counts as capturing the screen, which hides the QR.
        app.launchArguments += ["-debug.disableScreenCaptureProtection", "YES"]
        app.launch()

        let courses = DemoFixture.shared.courseNames.map { NSPredicate(format: "label == %@", $0) }
        let course = app.staticTexts.matching(NSCompoundPredicate(orPredicateWithSubpredicates: courses)).firstMatch
        XCTAssertTrue(course.waitForExistence(timeout: 120), "no classes from the phone")
        save(to: output, "02-next-class")

        app.swipeLeft()
        XCTAssertTrue(course.waitForExistence(timeout: 15))
        save(to: output, "01-today")

        app.swipeRight()
        app.swipeRight()
        XCTAssertTrue(app.staticTexts[DemoFixture.shared.studentId].waitForExistence(timeout: 60), "no library QR")
        save(to: output, "03-library-qr")
    }

    private func save(to directory: URL, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        XCTAssertNoThrow(try png.write(to: directory.appending(path: "\(name).png")))
    }
}
