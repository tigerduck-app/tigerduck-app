#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// A sign-out in another window re-renders the view presenting the colour sheet, which builds the
/// sheet again with a sign-in check made under the next account. A preset tapped after that still
/// saves nothing (https://github.com/tigerduck-app/tigerduck-app/issues/482).
@MainActor
@Suite(.serialized)
struct CourseColorPickerSheetTests {
    @Observable final class Login {
        var generation = 0
    }

    private final class Picks {
        var hexes: [UInt32] = []
    }

    /// The generation `Presenter` last built the sheet under.
    private final class Built {
        var generation: Int?
        func record(_ generation: Int) { self.generation = generation }
    }

    /// Reads the generation in `body`, as the class table's sheet closure does.
    private struct Presenter: View {
        let login: Login
        let course: SDCourse
        let picks: Picks
        let built: Built

        var body: some View {
            let generation = login.generation
            let _ = built.record(generation)
            CourseColorPickerSheet(
                course: course,
                isCurrent: { login.generation == generation },
                onSelect: { picks.hexes.append($0) }
            )
        }
    }

    @Test(arguments: [false, true])
    func aPresetSavesOnlyForTheAccountThatOpenedTheSheet(signsOut: Bool) async throws {
        try Self.setAccessibilityAutomation(true)
        defer { try? Self.setAccessibilityAutomation(false) }
        let login = Login()
        let picks = Picks()
        let built = Built()
        let course = SDCourse(courseNo: "CS1010001", courseName: "A", schedule: [2: ["3"]])
        let host = UIHostingController(rootView: Presenter(login: login, course: course, picks: picks, built: built))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        let label = String(format: String(localized: "a11y_course_color_swatch"), 1)
        try await waitUntil { Self.element(labeled: label, in: host.view) != nil }
        if signsOut {
            login.generation += 1
            try await waitUntil { built.generation == login.generation }
        }
        let swatch = try #require(Self.element(labeled: label, in: host.view))
        _ = swatch.accessibilityActivate()

        #expect(picks.hexes == (signsOut ? [] : [TigerDuckTheme.coursePaletteHexes[0]]))
    }

    /// SwiftUI builds its accessibility tree only for a client such as VoiceOver or UI testing,
    /// and a simulator without one, as in CI, leaves the swatch out; this turns it on as UI
    /// testing does.
    private static func setAccessibilityAutomation(_ on: Bool) throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let library = try #require(dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW))
        let symbol = try #require(dlsym(library, "_AXSSetAutomationEnabled"))
        typealias SetEnabled = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(on)
    }

    private static func element(labeled label: String, in node: NSObject) -> NSObject? {
        if node.accessibilityLabel == label { return node }
        var children = node.accessibilityElements ?? []
        let count = node.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { node.accessibilityElement(at: $0) }
        }
        if let view = node as? UIView { children += view.subviews }
        for case let child as NSObject in children {
            if let found = element(labeled: label, in: child) { return found }
        }
        return nil
    }
}
#endif
