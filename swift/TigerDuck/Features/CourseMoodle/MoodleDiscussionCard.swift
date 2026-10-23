import SwiftUI

struct MoodleDiscussionCard: View {
    let discussion: MoodleDiscussion
    let date: Date
    let policy: VisualStylePolicy
    var showsFooter = false
    var now: Date = AppClock.now()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var dotLift: CGFloat = 6

    private var isUnread: Bool { discussion.unreadCount > 0 }
    private var hasAttachments: Bool { !discussion.attachments.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    unreadDot
                    pin
                    attachmentMark
                    time
                }
                title
            } else {
                MoodleCardFirstLine {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        unreadDot
                        pin
                        title
                    }
                } trailing: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        attachmentMark
                        time
                    }
                }
            }
            if !discussion.preview.isEmpty {
                Text(discussion.preview)
                    .font(policy.preset == .iosInspired ? .subheadline : TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
            if showsFooter, authorName != nil || discussion.replyCount > 0 {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPadding()
        .presetCard(policy: policy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(discussion: discussion, date: date, showsFooter: showsFooter))
    }

    private var authorName: String? { Self.authorName(of: discussion) }

    private static func authorName(of discussion: MoodleDiscussion) -> String? {
        discussion.authorName.map(MoodlePersonName.displayName).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let authorName {
                MoodleAvatar(name: authorName, size: 18)
                Text(authorName)
                    .lineLimit(1)
            }
            Spacer(minLength: TigerDuckTheme.Spacing.sm)
            if discussion.replyCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left")
                    Text(discussion.replyCount, format: .number)
                        .monospacedDigit()
                }
                .fixedSize()
            }
        }
        .font(TigerDuckTheme.Typography.caption)
        .foregroundStyle(Color.textSecondary)
    }

    @ViewBuilder
    private var unreadDot: some View {
        if isUnread {
            Circle()
                .fill(.tint)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + dotLift }
        }
    }

    @ViewBuilder
    private var pin: some View {
        if discussion.isPinned {
            Image(systemName: "pin.fill")
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.schoolOrange)
        }
    }

    @ViewBuilder
    private var attachmentMark: some View {
        if hasAttachments {
            Image(systemName: "paperclip")
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var title: some View {
        Text(discussion.title)
            .font(TigerDuckTheme.Typography.headline)
            .fontWeight(isUnread ? .semibold : .regular)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }

    private var time: some View {
        Text(date.moodleListDateString(now: now))
            .font(TigerDuckTheme.Typography.caption)
            .monospacedDigit()
            .foregroundStyle(Color.textSecondary)
            .fixedSize()
    }

    static func accessibilityText(discussion: MoodleDiscussion, date: Date, showsFooter: Bool) -> String {
        var style = Date.FormatStyle(date: .long, time: .shortened)
        style.timeZone = AppConstants.taipeiTimeZone
        var parts: [String] = []
        if discussion.unreadCount > 0 { parts.append(String(localized: "bulletin_unread_dot_label")) }
        if discussion.isPinned { parts.append(String(localized: "course_forum_pinned")) }
        parts.append(discussion.title)
        parts.append(date.formatted(style))
        if !discussion.preview.isEmpty { parts.append(discussion.preview) }
        if !discussion.attachments.isEmpty { parts.append(String(localized: "school_mail_attachments")) }
        if showsFooter {
            if let name = authorName(of: discussion) { parts.append(name) }
            if discussion.replyCount > 0 {
                parts.append("\(String(localized: "school_mail_reply")) \(discussion.replyCount.formatted())")
            }
        }
        return parts.joined(separator: ", ")
    }
}

struct MoodleCardFirstLine<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .fixedSize()
                .layoutPriority(1)
        }
    }
}
