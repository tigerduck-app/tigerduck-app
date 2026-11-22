import XCTest

/// `tools/app_store_screenshots.py` runs these with `SCREENSHOTS_DIR`; without it they skip.
final class AppStoreScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private var outputDirectory: URL!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SCREENSHOTS_DIR"] else {
            throw XCTSkip("SCREENSHOTS_DIR is not set")
        }
        outputDirectory = URL(filePath: directory, directoryHint: .isDirectory)
        continueAfterFailure = false
        app = XCUIApplication()
        // The debug build's switch: a UI test counts as capturing the screen, and the protected
        // password field then never takes keyboard focus.
        app.launchArguments += ["-debug.disableScreenCaptureProtection", "YES"]
        if let clock = environment["SCREENSHOTS_CLOCK"] {
            app.launchArguments += ["-debug.clock.override", clock]
        }
        app.launchEnvironment["TZ"] = "Asia/Taipei"
        app.launch()
        signInIfNeeded()
    }

    override func tearDownWithError() throws {
        guard let outputDirectory, (testRun?.totalFailureCount ?? 0) > 0 else { return }
        let name = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.last ?? "test"
        try? [app.debugDescription, springboard.debugDescription].joined(separator: "\n\n").write(
            to: outputDirectory.appending(path: "\(name)-failed.txt"), atomically: true, encoding: .utf8
        )
    }

    @MainActor
    func test01Home() throws {
        let assignment = app.buttons.matching(labelStartingWith: DemoFixture.shared.moodleAssignmentTitle).firstMatch
        XCTAssertTrue(assignment.waitForExistence(timeout: 15))
        capture("01-home")
    }

    @MainActor
    func test02ClassTable() throws {
        openTab("feature_class_table_short")
        XCTAssertTrue(courseButton(DemoFixture.shared.moodleCourseName).waitForExistence(timeout: 15))
        capture("02-class-table")
    }

    @MainActor
    func test03CourseMembers() throws {
        openMoodleCourseRow("course_detail_members_label")
        capture("03-course-members")
    }

    @MainActor
    func test04CourseAnnouncements() throws {
        openMoodleCourseRow("feature_announcements")
        capture("04-course-announcements")
    }

    @MainActor
    func test05Assignment() throws {
        let row = app.buttons.matching(labelStartingWith: DemoFixture.shared.moodleAssignmentTitle).firstMatch
        tap(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 15))
        capture("05-assignment")
    }

    @MainActor
    func test06Scores() throws {
        openFeature("feature_score")
        capture("06-scores")
    }

    @MainActor
    func test07Mail() throws {
        openFeature("feature_school_mail")
        let signIn = app.buttons[text("action_sign_in")].firstMatch
        // The sign-in card comes filled in with the school account, which is also the demo mailbox's.
        if signIn.waitForExistence(timeout: 5) {
            signIn.tap()
            let notificationPermission = springboard.alerts.firstMatch
            if notificationPermission.waitForExistence(timeout: 10) {
                notificationPermission.buttons.element(boundBy: 1).tap()
            }
        }
        XCTAssertTrue(signIn.waitForNonExistence(timeout: 30))
        capture("07-mail")
    }

    @MainActor
    func test08Calendar() throws {
        openFeature("feature_calendar")
        capture("08-calendar")
    }

    @MainActor
    func test09LibraryQR() throws {
        openFeature("feature_library")
        capture("09-library-qr")
    }

    @MainActor
    func test10LiveActivityLockScreen() throws {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        XCTAssertTrue(wait(timeout: 30) { self.liveActivity.exists }, "no Live Activity on the Lock Screen")
        // The first time, iOS asks under the activity whether to allow the app's Live Activities,
        // with Allow second.
        let answers = springboard.buttons.matching(identifier: "swipe-action-button-identifier")
        if answers.count == 2 {
            answers.element(boundBy: 1).tap()
            XCTAssertTrue(answers.firstMatch.waitForNonExistence(timeout: 10))
        }
        capture("10-live-activity-lock-screen")
        XCUIDevice.shared.press(.home)
    }

    @MainActor
    func test11LiveActivityDynamicIsland() throws {
        // Over the Home Screen the island would sit above the UI test runner's icon.
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
        XCTAssertTrue(wait(timeout: 30) { self.liveActivity.exists }, "no Live Activity in the Dynamic Island")
        liveActivity.press(forDuration: 1)
        capture("11-live-activity-dynamic-island")
        XCUIDevice.shared.press(.home)
    }

    @MainActor
    func test12EmptyClassrooms() throws {
        openFeature("feature_empty_classroom")
        capture("12-empty-classrooms")
    }

    @MainActor
    func test13Clubs() throws {
        openTab("feature_class_table_short")
        tap(app.buttons[text("class_table_more_actions")].firstMatch)
        tapButton("class_table_subscribe_clubs")
        XCTAssertTrue(app.searchFields[text("class_table_club_search_prompt")].waitForExistence(timeout: 15))
        capture("13-clubs")
    }

    // MARK: - Steps

    private func signInIfNeeded() {
        let home = tabButton("feature_home_short")
        let next = app.buttons[text("action_next")].firstMatch
        XCTAssertTrue(wait(timeout: 30) { home.exists || next.exists }, "neither onboarding nor the tab bar")
        guard !home.exists else { return }
        tapButton("action_next")
        for key in ["onboarding_privacy_policy_label", "onboarding_privacy_delete_account_label"] {
            let toggle = app.switches[text(key)].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), key)
            toggle.tap()
        }
        tapButton("action_next")
        tapButton("action_next")
        if !UIDevice.isPad { tapButton("action_next") }
        let account = DemoFixture.shared
        let studentId = app.textFields[text("sign_in_student_id")].firstMatch
        XCTAssertTrue(studentId.waitForExistence(timeout: 10))
        studentId.tap()
        studentId.typeText(account.studentId)
        // The password field keeps its placeholder out of the accessibility tree; return signs in.
        let password = app.secureTextFields.firstMatch
        password.tap()
        password.typeText(account.password + "\n")
        tapButtonPastPasswordOffer("onboarding_skip_for_now")
        tapButtonPastPasswordOffer("onboarding_start_button")
        XCTAssertTrue(home.waitForExistence(timeout: 30))
        // An offer that has not come yet can come over Home; a new launch starts without it.
        app.terminate()
        app.launch()
        XCTAssertTrue(home.waitForExistence(timeout: 30))
    }

    private func openTab(_ key: String) {
        tap(tabButton(key))
    }

    private func openFeature(_ key: String) {
        let shortKey = key + "_short"
        if tabButton(shortKey).exists {
            openTab(shortKey)
        } else {
            openTab("feature_more_short")
            let row = app.buttons[text(key)].firstMatch
            // More makes its rows as they scroll into view, as on the iPhone Duo's cover screen.
            for _ in 0..<3 where !row.waitForExistence(timeout: 3) {
                app.swipeUp()
            }
            tap(row)
            XCTAssertTrue(row.waitForNonExistence(timeout: 15))
        }
    }

    /// An iPad's floating tab bar is not in `tabBars`.
    private func tabButton(_ key: String) -> XCUIElement {
        let label = text(key)
        let phone = app.tabBars.buttons[label]
        return phone.exists ? phone : app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func openMoodleCourseRow(_ key: String) {
        openTab("feature_class_table_short")
        tap(courseButton(DemoFixture.shared.moodleCourseName))
        let row = app.buttons.matching(labelStartingWith: text(key)).firstMatch
        tap(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 15))
    }

    /// The Lock Screen's activity names its course; the Dynamic Island's compact one, only the room.
    private var liveActivity: XCUIElement {
        let texts = DemoFixture.shared.courses.flatMap { [$0.name.shown, $0.classroom].compactMap(\.self) }
        let labels = texts.map { NSPredicate(format: "label CONTAINS %@", $0) }
        return springboard.descendants(matching: .any)
            .matching(NSCompoundPredicate(orPredicateWithSubpredicates: labels)).firstMatch
    }

    private func courseButton(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    // MARK: - Helpers

    /// The target's Generate Localizations phase gives this bundle the app's strings.
    private func text(_ key: String) -> String {
        let value = Bundle(for: Self.self).localizedString(forKey: key, value: nil, table: nil)
        XCTAssertNotEqual(value, key, "no string for \(key)")
        return value
    }

    /// The onboarding pages keep their neighbors' buttons in the tree.
    private func shownButton(_ key: String) -> XCUIElement? {
        app.buttons.matching(NSPredicate(format: "label == %@", text(key))).allElementsBoundByIndex
            .first { $0.isHittable && $0.isEnabled }
    }

    private func tapButton(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        var shown: XCUIElement?
        let found = wait {
            shown = self.shownButton(key)
            return shown != nil
        }
        XCTAssertTrue(found, "no \(key) button on screen", file: file, line: line)
        shown?.tap()
    }

    /// After the sign-in, iOS offers to save the password in an alert, once, at a moment no element
    /// marks; Not Now is its first button.
    private func tapButtonPastPasswordOffer(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        let offer = app.alerts.firstMatch
        var declined = false
        while true {
            var shown: XCUIElement?
            let found = wait {
                shown = self.shownButton(key)
                return shown != nil || (!declined && offer.exists)
            }
            XCTAssertTrue(found, "no \(key) button on screen", file: file, line: line)
            guard found, !declined, offer.exists else {
                shown?.tap()
                return
            }
            offer.buttons.firstMatch.tap()
            declined = true
        }
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "\(element)", file: file, line: line)
        element.tap()
    }

    private func wait(timeout: TimeInterval = 15, until condition: @escaping () -> Bool) -> Bool {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter().wait(for: [met], timeout: timeout) == .completed
    }

    private func capture(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        XCTAssertNoThrow(try png.write(to: outputDirectory.appending(path: "\(name).png")))
    }
}

private extension XCUIElementQuery {
    func matching(labelStartingWith prefix: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
    }
}

private extension UIDevice {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}
