import Foundation
import SwiftUI
import Testing
@testable import TigerDuck

struct MoodleDateFormatTests {
    private static func taipei(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        AppConstants.taipeiCalendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private static let now = taipei(2026, 10, 13, 9, 41)

    @Test("a list shows the time today, the zero-padded day this year, and the year before it")
    func listStamps() {
        #expect(Self.taipei(2026, 10, 13, 10, 24).moodleListDateString(now: Self.now) == "10:24")
        #expect(Self.taipei(2026, 10, 13, 0, 5).moodleListDateString(now: Self.now) == "00:05")
        #expect(Self.taipei(2026, 9, 8, 7, 5).moodleListDateString(now: Self.now) == "09/08")
        #expect(Self.taipei(2025, 12, 30, 23, 59).moodleListDateString(now: Self.now) == "2025/12/30")
    }

    @Test("a file's date is the zero-padded day, with the year when it is not this one, never the time")
    func fileDates() {
        #expect(Self.taipei(2026, 10, 13, 10, 24).moodleDateString(now: Self.now) == "10/13")
        #expect(Self.taipei(2026, 1, 2).moodleDateString(now: Self.now) == "01/02")
        #expect(Self.taipei(2024, 3, 4).moodleDateString(now: Self.now) == "2024/03/04")
    }

    @Test("an article's masthead carries the full date and time")
    func masthead() {
        #expect(Self.taipei(2026, 10, 13, 10, 24).moodleDateTimeString == "2026/10/13 10:24")
    }

    @Test("a discussion's post shows its day and time, with the year when it is not this one")
    func postStamps() {
        #expect(Self.taipei(2026, 10, 13, 9, 30).moodlePostDateString(now: Self.now) == "10/13 09:30")
        #expect(Self.taipei(2026, 1, 2, 23, 5).moodlePostDateString(now: Self.now) == "01/02 23:05")
        #expect(Self.taipei(2025, 12, 31, 8, 0).moodlePostDateString(now: Self.now) == "2025/12/31 08:00")
    }
}

#if os(iOS)
import UIKit

@MainActor
struct MoodleDiscussionCardTests {
    private final class Frames: @unchecked Sendable {
        var frames: [String: CGRect] = [:]
    }

    private static let longText = String(repeating: "期中考範圍與注意事項，請各組於本週五前登記期末專題題目。", count: 6)

    private func layout(_ view: some View, width: CGFloat = 390) -> [String: CGRect] {
        let frames = Frames()
        let host = UIHostingController(
            rootView: VStack(spacing: 0) { view; Spacer(minLength: 0) }
                .frame(width: width, height: 900)
                .coordinateSpace(.named("root"))
                .environment(\.frameProbe, { name, frame in frames.frames[name] = frame })
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.isHidden = true
        return frames.frames
    }

    private func height(_ view: some View, width: CGFloat = 390) throws -> CGFloat {
        try #require(layout(view.probe("view"), width: width)["view"]).height
    }

    @Test("the time keeps its whole width on the first line beside a title of any length, which stops at two lines")
    func firstLineKeepsTheTime() throws {
        let time = "2025/12/30"
        let timeWidth = try #require(layout(Text(time).font(.caption).monospacedDigit().fixedSize().probe("time"))["time"]).width
        let lineHeight = try height(Text(verbatim: "期").font(.headline))
        let twoLines = try height(Text(verbatim: "期\n期").font(.headline))

        for title in ["Midterm", Self.longText] {
            let frames = layout(MoodleCardFirstLine {
                Text(title).font(.headline).lineLimit(2).probe("title")
            } trailing: {
                Text(time).font(.caption).monospacedDigit().probe("time")
            }, width: 300)
            let titleFrame = try #require(frames["title"])
            let timeFrame = try #require(frames["time"])
            #expect(abs(timeFrame.width - timeWidth) < 0.5, "time \(timeFrame.width)pt of \(timeWidth)pt")
            #expect(timeFrame.maxY <= titleFrame.minY + lineHeight + 1, "time not on the title's first line")
            #expect(titleFrame.height <= twoLines + 0.5, "title over two lines")
        }
    }

    @Test("a card's title and preview stop at two lines, ending in an ellipsis rather than growing the card")
    func cardClampsTitleAndPreview() throws {
        let policy = VisualStylePolicy(preset: .default)
        func card(_ title: String, _ preview: String) -> MoodleDiscussionCard {
            MoodleDiscussionCard(
                discussion: MoodleDiscussion(
                    id: 801, postId: 7001, title: title, message: "", preview: preview,
                    created: .now, modified: .now, isPinned: true, unreadCount: 1, replyCount: 0,
                    authorName: nil, attachments: [MoodleFile(name: "a.pdf", size: 1, url: "https://example.com/a.pdf", mimeType: nil, modified: nil)]
                ),
                date: .now,
                policy: policy
            )
        }

        let short = try height(card("Midterm", "Bring your ID."))
        let long = try height(card(Self.longText, Self.longText))
        let longer = try height(card(Self.longText + Self.longText, Self.longText + Self.longText))

        #expect(long > short)
        #expect(abs(longer - long) < 0.5, "card grew from \(long)pt to \(longer)pt")
    }
}

private struct FrameProbeKey: EnvironmentKey {
    static let defaultValue: @MainActor (String, CGRect) -> Void = { _, _ in }
}

private extension EnvironmentValues {
    var frameProbe: @MainActor (String, CGRect) -> Void {
        get { self[FrameProbeKey.self] }
        set { self[FrameProbeKey.self] = newValue }
    }
}

private struct FrameProbe: ViewModifier {
    let name: String
    @Environment(\.frameProbe) private var report

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry -> Color in
                report(name, geometry.frame(in: .named("root")))
                return Color.clear
            }
        )
    }
}

private extension View {
    func probe(_ name: String) -> some View {
        modifier(FrameProbe(name: name))
    }
}
#endif
