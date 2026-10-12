import SwiftUI

/// A discussion in a Moodle list: its title beside its time, then a preview of its message.
/// At accessibility sizes the marks and the time take their own line above the title.
struct MoodleDiscussionCard: View {
    let discussion: MoodleDiscussion
    /// The time the card shows: the posting time for an announcement.
    let date: Date
    let policy: VisualStylePolicy
    var now: Date = AppClock.now()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Lifts the unread dot's centre to the middle of the title's capitals.
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPadding()
        .presetCard(policy: policy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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

    private var accessibilityText: String {
        var style = Date.FormatStyle(date: .long, time: .shortened)
        style.timeZone = AppConstants.taipeiTimeZone
        var parts: [String] = []
        if isUnread { parts.append(String(localized: "bulletin_unread_dot_label")) }
        if discussion.isPinned { parts.append(String(localized: "course_forum_pinned")) }
        parts.append(discussion.title)
        parts.append(date.formatted(style))
        if !discussion.preview.isEmpty { parts.append(discussion.preview) }
        if hasAttachments { parts.append(String(localized: "school_mail_attachments")) }
        return parts.joined(separator: ", ")
    }
}

/// The first line of a Moodle card. `trailing`, the time, keeps its whole width and stays on the
/// first line of `leading`'s text however long that runs; `leading` takes the width left.
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
