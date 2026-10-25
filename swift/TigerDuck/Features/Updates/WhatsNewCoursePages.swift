#if os(iOS)
import SwiftUI
import WatchConnectivity

extension WhatsNewPage {
    static let moodleInCourseDetail = WhatsNewPage.feature(
        id: "moodle-in-course-detail",
        visual: .custom { WhatsNewMoodleSectionsDemo() },
        title: WhatsNewText(en: "Moodle in course details", zhHant: "課程的 Moodle 內容"),
        body: WhatsNewText(
            en: "See a course's announcements, materials, forums, members and grades.",
            zhHant: "課程詳情可看公告、教材、討論區、成員與成績。"
        )
    )

    static let classReminderSettings = WhatsNewPage.feature(
        id: "class-reminder-settings",
        visual: .custom { WhatsNewClassReminderDemo() },
        title: WhatsNewText(en: "Class reminder settings", zhHant: "上課提醒設定"),
        body: WhatsNewText(
            en: "Turn class reminders off or choose how early they come.",
            zhHant: "可關閉上課提醒，或調整提前通知的時間。"
        )
    )

    static let watchComplication = WhatsNewPage.feature(
        id: "watch-complication",
        visual: .custom { WhatsNewWatchComplicationDemo() },
        title: WhatsNewText(en: "Apple Watch complication", zhHant: "Apple Watch 錶面"),
        body: WhatsNewText(
            en: "See your next class right on the watch face.",
            zhHant: "錶面直接顯示下一堂課。"
        ),
        // isPaired reads false until the session WatchSyncCoordinator starts at launch activates, so
        // an upgrade launch can skip the page for a paired Watch too; the Settings replay shows it.
        isApplicable: { _ in
            WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isPaired
        }
    )
}

struct WhatsNewMoodleSectionsDemo: View {
    @Environment(\.whatsNewLanguage) private var language
    @Environment(\.whatsNewPageIsCurrent) private var isCurrent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownRows = 0

    private static let rows: [(symbol: String, title: WhatsNewText)] = [
        ("megaphone", WhatsNewText(en: "Announcements", zhHant: "公告")),
        ("folder", WhatsNewText(en: "Materials", zhHant: "教材")),
        ("bubble.left.and.bubble.right", WhatsNewText(en: "Forums", zhHant: "討論區")),
        ("person.2", WhatsNewText(en: "Members", zhHant: "成員")),
        ("chart.bar", WhatsNewText(en: "Grades", zhHant: "成績")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(WhatsNewText(en: "Programming", zhHant: "程式設計").resolved(for: language))
                .font(.headline)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.vertical, TigerDuckTheme.Spacing.sm)
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: TigerDuckTheme.Spacing.md) {
                    Image(systemName: row.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    Text(row.title.resolved(for: language))
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.vertical, 7)
                .opacity(index < shownRows ? 1 : 0)
                .offset(x: index < shownRows || reduceMotion ? 0 : 24)
            }
        }
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous))
        .padding(.horizontal, TigerDuckTheme.Spacing.xxl)
        .task(id: isCurrent) {
            guard isCurrent else { return }
            shownRows = 0
            while !Task.isCancelled {
                for row in 1...Self.rows.count {
                    try? await Task.sleep(for: .milliseconds(260))
                    guard !Task.isCancelled else { return }
                    withAnimation(.snappy(duration: 0.3)) { shownRows = row }
                }
                try? await Task.sleep(for: .seconds(2.2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { shownRows = 0 }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WhatsNewText(
            en: "A course's details with Announcements, Materials, Forums, Members and Grades.",
            zhHant: "課程詳情裡的公告、教材、討論區、成員與成績。"
        ).resolved(for: language))
    }
}

struct WhatsNewClassReminderDemo: View {
    @Environment(\.whatsNewLanguage) private var language
    @Environment(\.whatsNewPageIsCurrent) private var isCurrent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lead = 10
    @State private var showsBanner = false

    private static let leads = [5, 10, 15, 30, 60]
    private static let sequence = [10, 15, 30, 5]

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            banner
                .opacity(showsBanner ? 1 : 0)
                .offset(y: showsBanner || reduceMotion ? 0 : -24)
                .padding(.horizontal, TigerDuckTheme.Spacing.xl)
            picker
        }
        .task(id: isCurrent) {
            guard isCurrent else { return }
            showsBanner = false
            var step = 0
            while !Task.isCancelled {
                withAnimation(.snappy(duration: 0.25)) { lead = Self.sequence[step % Self.sequence.count] }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.35)) { showsBanner = true }
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) { showsBanner = false }
                try? await Task.sleep(for: .milliseconds(300))
                step += 1
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WhatsNewText(
            en: "A class reminder that comes 5, 10, 15 or 30 minutes or an hour before class.",
            zhHant: "上課前 5、10、15、30 分鐘或 1 小時的上課提醒。"
        ).resolved(for: language))
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(WhatsNewText(en: "Class reminder", zhHant: "上課提醒").resolved(for: language))
                    .font(.subheadline.weight(.semibold))
                Text(String(
                    format: WhatsNewText(
                        en: "Programming starts in %d min · TR-313",
                        zhHant: "程式設計 %d 分鐘後開始 · TR-313"
                    ).resolved(for: language),
                    lead
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(TigerDuckTheme.Spacing.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var picker: some View {
        HStack(spacing: 6) {
            ForEach(Self.leads, id: \.self) { minutes in
                Text(minutes == 60
                    ? WhatsNewText(en: "1 hr", zhHant: "1 小時").resolved(for: language)
                    : String(format: WhatsNewText(en: "%d min", zhHant: "%d 分").resolved(for: language), minutes))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(minutes == lead ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    if minutes == lead {
                        Capsule().fill(.tint)
                    } else {
                        Capsule().fill(Color(uiColor: .tertiarySystemFill))
                    }
                }
            }
        }
    }
}

struct WhatsNewWatchComplicationDemo: View {
    @Environment(\.whatsNewLanguage) private var language
    @Environment(\.whatsNewPageIsCurrent) private var isCurrent
    @State private var index = 0

    private static let classes: [(name: WhatsNewText, time: String, room: String)] = [
        (WhatsNewText(en: "Programming", zhHant: "程式設計"), "10:20", "TR-313"),
        (WhatsNewText(en: "Calculus", zhHant: "微積分"), "13:20", "IB-201"),
    ]

    var body: some View {
        let next = Self.classes[index]
        ZStack {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(Color.black)
                .overlay {
                    RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .strokeBorder(Color.gray.opacity(0.5), lineWidth: 6)
                }
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                Text("10:09")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WhatsNewText(en: "Next class", zhHant: "下一堂課").resolved(for: language))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(next.name.resolved(for: language))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("\(next.time) · \(next.room)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .id(index)
                .transition(.opacity)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(20)
        }
        .frame(width: 190, height: 220)
        .overlay(alignment: .trailing) {
            Capsule()
                .fill(Color.gray.opacity(0.6))
                .frame(width: 8, height: 36)
                .offset(x: 6, y: -30)
        }
        .frame(maxWidth: .infinity)
        .task(id: isCurrent) {
            guard isCurrent else { return }
            index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.35)) { index = (index + 1) % Self.classes.count }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WhatsNewText(
            en: "An Apple Watch face showing the next class.",
            zhHant: "顯示下一堂課的 Apple Watch 錶面。"
        ).resolved(for: language))
    }
}
#endif
