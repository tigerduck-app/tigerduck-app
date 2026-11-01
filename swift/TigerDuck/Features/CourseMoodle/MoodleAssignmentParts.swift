#if os(iOS)
import MarkdownUI
import SwiftUI

struct MoodleAssignmentSectionTitle: View {
    let title: String

    var body: some View {
            Text(title)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
    }
}

struct MoodleAssignmentTimeRow: View {
    let label: String
    let time: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let time {
                Text(time)
                    .monospacedDigit()
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.textSecondary)
        .accessibilityElement(children: .combine)
    }
}

struct MoodleAssignmentMarkdown: View {
    let text: String
    let accent: Color
    let files: MoodleFileOpener

    @Environment(\.openMoodleLink) private var openMoodleLink

    var body: some View {
        Markdown(text)
            .markdownTheme(.bulletin(accent: accent))
            .environment(\.openURL, OpenURLAction { url in
                files.forgetPendingOpen()
                openMoodleLink(url)
                return .handled
            })
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MoodleAssignmentFileRows: View {
    let refs: [MoodleFileRef]
    let store: MoodleCourseStore
    let files: MoodleFileOpener
    let openOnMoodle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(refs.enumerated()), id: \.offset) { index, ref in
                if index > 0 {
                    Divider().padding(.leading, MoodleFileRow.textInset)
                }
                MoodleFileRow(
                    title: ref.file.name,
                    file: ref.file,
                    state: store.downloadState(of: ref.file, in: ref.owner),
                    tap: { files.tap(ref, among: refs, store: store) },
                    share: { files.share(ref, store: store) },
                    openInMoodle: openOnMoodle
                )
            }
        }
    }
}
#endif
