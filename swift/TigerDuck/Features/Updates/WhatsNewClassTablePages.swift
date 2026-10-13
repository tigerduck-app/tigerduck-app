#if os(iOS)
import SwiftUI

extension WhatsNewPage {
    /// 2.4.0: class tables shared by QR code, and switched from the Class table tab.
    static let classTableSharing = WhatsNewPage.feature(
        id: "class-table-sharing",
        visual: .custom { WhatsNewClassTableSwitchDemo() },
        title: WhatsNewText(en: "Share and switch class tables", zhHant: "分享與切換課表"),
        body: WhatsNewText(
            en: "Share and import friends' class tables by QR code. Touch and hold or double-tap the Class table tab to switch.",
            zhHant: "用 QR Code 分享、匯入朋友的課表。長按或雙擊課表可以切換。"
        )
    )

    /// 2.4.0: every assignment of a course ignored at once, with its due reminders.
    static let ignoreCourseAssignments = WhatsNewPage.feature(
        id: "ignore-course-assignments",
        visual: .custom { WhatsNewIgnoreAssignmentsDemo() },
        title: WhatsNewText(en: "Ignore a course's assignments", zhHant: "忽略整門課的作業"),
        body: WhatsNewText(
            en: "Ignore all of a course's assignments and their due reminders.",
            zhHant: "忽略某門課的所有作業與繳交通知。"
        )
    )
}

/// A small class table that a double tap on the Class table tab switches between the user's and a
/// friend's. As on the real one, only the courses the two differ in fade; the rest stay put.
struct WhatsNewClassTableSwitchDemo: View {
    @Environment(\.whatsNewLanguage) private var language
    @Environment(\.whatsNewPageIsCurrent) private var isCurrent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsFriend = false
    @State private var taps = 0

    private struct Block: Identifiable {
        let name: WhatsNewText
        let hex: UInt
        let day: Int
        let period: Int
        let span: Int
        var id: String { "\(name.en) \(day) \(period) \(span)" }
    }

    private static let days = 5
    private static let periods = 4
    private static let gap: CGFloat = 3

    private static let calculus = WhatsNewText(en: "Calculus", zhHant: "微積分")
    private static let english = WhatsNewText(en: "English", zhHant: "英文")
    private static let mine: [Block] = [
        Block(name: calculus, hex: 0x4ECDC4, day: 0, period: 0, span: 2),
        Block(name: WhatsNewText(en: "Physics", zhHant: "物理"), hex: 0xFF6B6B, day: 1, period: 1, span: 2),
        Block(name: english, hex: 0xF7DC6F, day: 2, period: 2, span: 1),
        Block(name: WhatsNewText(en: "Programming", zhHant: "程式設計"), hex: 0x3498DB, day: 3, period: 0, span: 2),
    ]
    private static let friends: [Block] = [
        Block(name: calculus, hex: 0x4ECDC4, day: 0, period: 0, span: 2),
        Block(name: WhatsNewText(en: "Economics", zhHant: "經濟學"), hex: 0xDDA0DD, day: 1, period: 0, span: 1),
        Block(name: english, hex: 0xF7DC6F, day: 2, period: 2, span: 1),
        Block(name: WhatsNewText(en: "Data Structures", zhHant: "資料結構"), hex: 0x2ECC71, day: 3, period: 2, span: 2),
        Block(name: WhatsNewText(en: "PE", zhHant: "體育"), hex: 0xF39C12, day: 4, period: 1, span: 2),
    ]

    /// The class table's own fade: the old course out, then the new one in.
    private static let courseFade = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.1))
    )

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            owner
            grid
            tab
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.xxl)
        .task(id: isCurrent) {
            guard isCurrent else { return }
            showsFriend = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                taps += 1
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                showsFriend.toggle()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WhatsNewText(
            en: "A class table that switches between yours and a friend's when the Class table tab is double-tapped.",
            zhHant: "雙擊「課表」分頁時，在你和朋友的課表之間切換。"
        ).resolved(for: language))
    }

    private var owner: some View {
        HStack(spacing: TigerDuckTheme.Spacing.xs) {
            Text((showsFriend
                ? WhatsNewText(en: "Alex", zhHant: "小明")
                : WhatsNewText(en: "You", zhHant: "你")).resolved(for: language))
                .contentTransition(.opacity)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.tint)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeInOut(duration: 0.2), value: showsFriend)
    }

    private var grid: some View {
        GeometryReader { proxy in
            let width = (proxy.size.width - Self.gap * CGFloat(Self.days - 1)) / CGFloat(Self.days)
            let height = (proxy.size.height - Self.gap * CGFloat(Self.periods - 1)) / CGFloat(Self.periods)
            let blocks = showsFriend ? Self.friends : Self.mine
            // As on the class table, a course's rows have no empty tile under them to show through.
            let covered = Set(blocks.flatMap { block in
                (block.period..<(block.period + block.span)).map { $0 * Self.days + block.day }
            })
            ZStack(alignment: .topLeading) {
                ForEach(0..<(Self.days * Self.periods), id: \.self) { slot in
                    if !covered.contains(slot) {
                        RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                            .fill(Color.cardSurface.opacity(0.15))
                            .frame(width: width, height: height)
                            .offset(x: CGFloat(slot % Self.days) * (width + Self.gap),
                                    y: CGFloat(slot / Self.days) * (height + Self.gap))
                            .transition(.identity)
                    }
                }
                ForEach(blocks) { block in
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                        .fill(Color(hex: block.hex).opacity(0.4))
                        .overlay {
                            Text(block.name.resolved(for: language))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .multilineTextAlignment(.center)
                                .padding(2)
                        }
                        .frame(width: width, height: CGFloat(block.span) * height + CGFloat(block.span - 1) * Self.gap)
                        .offset(x: CGFloat(block.day) * (width + Self.gap),
                                y: CGFloat(block.period) * (height + Self.gap))
                        .transition(Self.courseFade)
                }
            }
        }
        .frame(height: 150)
        .animation(.linear(duration: 0.25), value: showsFriend)
    }

    /// The Class table tab, rippling twice for the double tap that switches.
    private var tab: some View {
        VStack(spacing: 2) {
            Image(systemName: AppFeature.classTable.iconName)
                .font(.system(size: 17))
            Text(WhatsNewText(en: "Class table", zhHant: "課表").resolved(for: language))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.tint)
        .frame(width: 64, height: 40)
        .background {
            Circle()
                .stroke(.tint, lineWidth: 2)
                .frame(width: 44, height: 44)
                .keyframeAnimator(initialValue: 0.0, trigger: taps) { content, progress in
                    content
                        .scaleEffect(reduceMotion ? 1 : 0.7 + progress * 0.7)
                        .opacity(progress == 0 ? 0 : 1 - progress)
                } keyframes: { _ in
                    LinearKeyframe(1.0, duration: 0.18)
                    LinearKeyframe(0.01, duration: 0.01)
                    LinearKeyframe(1.0, duration: 0.18)
                }
        }
    }
}

/// A course block whose menu ignores its assignments: the assignment mark turns into the slashed
/// book the class table shows, and the course's due reminders stop.
struct WhatsNewIgnoreAssignmentsDemo: View {
    @Environment(\.whatsNewLanguage) private var language
    @Environment(\.whatsNewPageIsCurrent) private var isCurrent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsMenu = false
    @State private var highlights = false
    @State private var ignored = false

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.lg) {
            course
            ZStack(alignment: .leading) {
                if showsMenu {
                    menu.transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                } else {
                    reminder.transition(.opacity)
                }
            }
            .frame(width: 180, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task(id: isCurrent) {
            guard isCurrent else { return }
            showsMenu = false
            highlights = false
            while !Task.isCancelled {
                ignored = false
                try? await Task.sleep(for: .seconds(1.3))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.25)) { showsMenu = true }
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.15)) { highlights = true }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    showsMenu = false
                    highlights = false
                    ignored = true
                }
                try? await Task.sleep(for: .seconds(2.2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) { ignored = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WhatsNewText(
            en: "A course's menu ignores its assignments, and its due reminders stop.",
            zhHant: "從課程的選單忽略作業後，這門課的繳交通知也會停止。"
        ).resolved(for: language))
    }

    private var course: some View {
        RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
            .fill(Color(hex: 0xDDA0DD).opacity(0.4))
            .frame(width: 92, height: 124)
            .overlay {
                Text(WhatsNewText(en: "Economics", zhHant: "經濟學").resolved(for: language))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if ignored {
                        IgnoredAssignmentsIcon(size: 12).transition(.opacity)
                    } else {
                        Image(systemName: "book.fill").font(.system(size: 12)).transition(.opacity)
                    }
                }
                .foregroundStyle(Color.textSecondary.opacity(0.6))
                .padding(6)
            }
            .scaleEffect(showsMenu && !reduceMotion ? 1.04 : 1)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("pencil", WhatsNewText(en: "Rename", zhHant: "重新命名"))
            Divider()
            menuRow("paintpalette", WhatsNewText(en: "Edit color", zhHant: "編輯顏色"))
            Divider()
            menuRow("archivebox", WhatsNewText(en: "Ignore assignments", zhHant: "忽略作業"))
                .background(highlights ? Color.primary.opacity(0.12) : .clear)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous))
    }

    private func menuRow(_ symbol: String, _ title: WhatsNewText) -> some View {
        HStack {
            Text(title.resolved(for: language))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: TigerDuckTheme.Spacing.sm)
            Image(systemName: symbol)
        }
        .font(.subheadline)
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, 10)
    }

    private var reminder: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: ignored ? "bell.slash" : "bell.badge")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(ignored ? AnyShapeStyle(Color.textSecondary) : AnyShapeStyle(.tint))
            Text(WhatsNewText(en: "Due reminders", zhHant: "繳交通知").resolved(for: language))
                .strikethrough(ignored)
                .foregroundStyle(ignored ? Color.textSecondary : Color.textPrimary)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
    }
}
#endif
