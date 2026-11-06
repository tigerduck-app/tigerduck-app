#if os(iOS)
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
import WidgetKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct WidgetLayoutTests {
    private typealias Fixtures = WidgetFixtures

    @MainActor
    enum Host {
        static func show(
            _ view: some View, size: CGSize, style: UIUserInterfaceStyle = .light,
            textSize: UIContentSizeCategory = .large, renderingMode: WidgetRenderingMode = .fullColor,
            background: Color? = nil, margins: CGFloat = 16
        ) throws -> UIWindow {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: size.width + 40, height: size.height + 40)
            window.overrideUserInterfaceStyle = style
            window.traitOverrides.preferredContentSizeCategory = textSize
            let backdrop = renderingMode == .fullColor
                ? AnyShapeStyle(Color(white: style == .dark ? 0.05 : 0.88))
                : AnyShapeStyle(LinearGradient(colors: [Color(red: 0.08, green: 0.13, blue: 0.22), Color(red: 0.12, green: 0.23, blue: 0.36)], startPoint: .topLeading, endPoint: .bottomTrailing))
            let widget = view
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(margins)
                .frame(width: size.width, height: size.height)
                .background(
                    background ?? (renderingMode == .fullColor ? .clear : Color(red: 0.47, green: 0.65, blue: 0.9).opacity(0.18)),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .environment(\.widgetRenderingMode, renderingMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backdrop)
            let host = UIHostingController(rootView: widget)
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
            return window
        }

        static func palette(style: UIUserInterfaceStyle = .light, renderingMode: WidgetRenderingMode = .fullColor) -> WidgetPalette {
            WidgetPalette.resolve(
                snapshot: WidgetFixtures.snapshot(), colorScheme: style == .dark ? .dark : .light, renderingMode: renderingMode
            )
        }

        static func texts(in window: UIWindow, waitingFor text: String) async throws -> [String] {
            try await waitUntil { exposedAccessibilityTexts(in: window).contains { $0.contains(text) } }
            return exposedAccessibilityTexts(in: window)
        }
    }

    static let large = CGSize(width: 329, height: 345)
    static let portrait = CGSize(width: 329, height: 535)

    @Test func theLargeTodayListShowsNoPeriodNumbers() async throws {
        try await withAccessibilityAutomation {
            let now = Fixtures.wednesday(11, 32)
            let view = TodayView(snapshot: Fixtures.snapshot(), now: now, palette: Host.palette(), family: .systemLarge)
            let window = try Host.show(view, size: Self.large)
            defer { window.isHidden = true }
            let texts = try await Host.texts(in: window, waitingFor: "資料結構與演算法")

            #expect(texts.contains { $0.contains("TR-412") })
            for periods in ["1–2", "3–4", "6–7"] {
                #expect(!texts.contains { $0.contains(periods) }, "\(texts) shows the periods \(periods)")
            }
        }
    }

    @Test func thePortraitTimelineShowsTodayAndNoClassOfTomorrow() async throws {
        try await withAccessibilityAutomation {
            let view = TodayTimelineView(snapshot: Fixtures.snapshot(), now: Fixtures.wednesday(11, 32), palette: Host.palette())
            let window = try Host.show(view, size: Self.portrait)
            defer { window.isHidden = true }
            let texts = try await Host.texts(in: window, waitingFor: "工程數學")

            #expect(texts.contains { $0.contains("通識：科技、社會與永續發展導論") })
            #expect(!texts.contains { $0.contains("線性代數") }, "\(texts) shows Thursday's first class")
        }
    }

    @Test func theWeekGridReadsTheTermsWeekInItsCorner() async throws {
        try await withAccessibilityAutomation {
            let spoken = String(format: String(localized: "a11y_class_table_week"), 9)
            let view = WeekGridView(snapshot: Fixtures.snapshot(), now: Fixtures.wednesday(11, 32), palette: Host.palette(), family: .systemLarge)
            let window = try Host.show(view, size: Self.large, margins: 8)
            defer { window.isHidden = true }

            try await waitUntil { accessibilityElement(labeled: spoken, in: window) != nil }
            let corner = try #require(accessibilityElement(labeled: spoken, in: window)).accessibilityFrame
            let monday = try #require(accessibilityElement(labeled: AppConstants.Periods.shortWeekdayLabel(1), in: window)).accessibilityFrame
            #expect(corner.maxX <= monday.minX + 0.5, "\(corner) is not left of Monday \(monday)")
            #expect(abs(corner.midY - monday.midY) < 1, "\(corner) is not beside Monday \(monday)")
        }
    }

    @Test func outsideTheTermTheCornerStaysEmpty() async throws {
        try await withAccessibilityAutomation {
            let spoken = String(format: String(localized: "a11y_class_table_week"), 9)
            let view = WeekGridView(
                snapshot: Fixtures.snapshot(term: nil), now: Fixtures.wednesday(11, 32), palette: Host.palette(), family: .systemLarge
            )
            let window = try Host.show(view, size: Self.large, margins: 8)
            defer { window.isHidden = true }
            _ = try await Host.texts(in: window, waitingFor: "TR-412")

            #expect(accessibilityElement(labeled: spoken, in: window) == nil)
        }
    }

    @Test(arguments: [(11, 32), (16, 0)])
    func theNextClassWidgetKeepsEachRoomWholeWhileTheNameGivesWay(hour: Int, minute: Int) async throws {
        try await withAccessibilityAutomation {
            let snapshot = Fixtures.snapshot(courses: Fixtures.week(long: true))
            let now = Fixtures.wednesday(hour, minute)
            let derived = WidgetTimelineDerivation.derive(snapshot: snapshot, at: now)
            let upNext = WidgetTimelineDerivation.upNext(snapshot: snapshot, at: now, after: derived)
            let view = NextClassView(derived: derived, upNext: upNext, palette: Host.palette(), family: .systemMedium, clock: now)
            let window = try Host.show(view, size: CGSize(width: 329, height: 155), margins: 11)
            defer { window.isHidden = true }
            let shown: [(name: String, room: String, font: Font)] = hour == 11
                ? [(Fixtures.longName, Fixtures.longRoom, .title.weight(.bold)), ("計算機網路概論", "IB-505", .headline.weight(.bold))]
                : [("體育－羽球", "GY-201", .title.weight(.bold)), ("通識：科技、社會與永續發展導論", "AU-105", .headline.weight(.bold))]
            for (name, room, font) in shown {
                try await waitUntil { accessibilityElement(labeled: room, in: window) != nil }
                let frame = try #require(accessibilityElement(labeled: room, in: window)).accessibilityFrame
                let ideal = Self.idealWidth(room, font: font)
                #expect(abs(frame.width - ideal) < 0.5, "\(room) is \(frame.width) pt of \(ideal)")
                let nameFrame = try #require(accessibilityElement(labeled: name, in: window)).accessibilityFrame
                #expect(nameFrame.maxX <= frame.minX + 0.5 || nameFrame.maxY <= frame.minY + 0.5, "\(name) runs into \(room)")
            }
        }
    }

    private static func idealWidth(_ text: String, font: Font) -> CGFloat {
        UIHostingController(rootView: Text(text).font(font))
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
    }

    @Test(arguments: [CGFloat(150), 200, 280])
    func theRoomStaysWholeWhileTheNameGivesWay(width: CGFloat) async throws {
        try await withAccessibilityAutomation {
            func line(_ room: String) -> some View {
                NameRoomLine(
                    name: Fixtures.longName, room: room, nameFont: .subheadline.weight(.semibold),
                    roomFont: .subheadline.weight(.bold), ink: .primary, changeInk: .orange
                )
            }
            let alone = try Host.show(
                WidgetRoom(room: Fixtures.longRoom, font: .subheadline.weight(.bold), ink: .primary, changeInk: .orange).fixedSize(),
                size: CGSize(width: 400, height: 60)
            )
            try await waitUntil { accessibilityElement(labeled: Fixtures.longRoom, in: alone) != nil }
            let ideal = try #require(accessibilityElement(labeled: Fixtures.longRoom, in: alone)).accessibilityFrame.width
            alone.isHidden = true

            let window = try Host.show(line(Fixtures.longRoom), size: CGSize(width: width + 32, height: 60))
            defer { window.isHidden = true }
            try await waitUntil { accessibilityElement(labeled: Fixtures.longRoom, in: window) != nil }
            let room = try #require(accessibilityElement(labeled: Fixtures.longRoom, in: window)).accessibilityFrame
            let name = try #require(accessibilityElement(labeled: Fixtures.longName, in: window)).accessibilityFrame

            #expect(abs(room.width - ideal) < 0.5, "the room is \(room.width) pt of its \(ideal)")
            #expect(name.maxX <= room.minX + 0.5, "\(name) runs into \(room)")
        }
    }
}
#endif
