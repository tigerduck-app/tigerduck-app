#if os(macOS)
import MarkdownUI
import SwiftUI

/// A bulletin opened in the Mac detail pane: its title, office, date, body and source link.
struct MacBulletinDetail: View {
    let detail: BulletinAPI.BulletinDetail
    /// The list's summary, shown when the bulletin has no body of its own.
    let fallback: String?
    let orgLabel: (String) -> String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.displayTitle)
                        .font(.title.bold())
                    HStack(spacing: 8) {
                        if let org = detail.canonicalOrg, !org.isEmpty {
                            Label(orgLabel(org), systemImage: "building.2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let posted = detail.postedAt {
                            Label(posted.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                let body = BulletinBodyRenderer.bodyMarkdown(
                    for: detail,
                    fallbackSummary: fallback
                )
                if body.isEmpty {
                    Text(String(localized: "desktop_bulletins_no_body"))
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Markdown(BulletinBodyRenderer.normalize(body))
                        .markdownTheme(.basic)
                        .textSelection(.enabled)
                }

                if let url = URL(string: detail.sourceUrl) {
                    Link(destination: url) {
                        Label(String(localized: "bulletin_source_link_label"), systemImage: "arrow.up.right.square")
                    }
                    .padding(.top, 8)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A bulletin whose body failed to load: the error, a retry button and the list's summary.
struct MacBulletinDetailError: View {
    let message: String
    let fallback: String?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(String(localized: "bulletin_body_load_failed"))
                    .font(.headline)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(String(localized: "action_retry"), action: retry)
            if let fallback, !fallback.isEmpty {
                Divider()
                Markdown(BulletinBodyRenderer.normalize(fallback))
                    .markdownTheme(.basic)
            }
        }
        .padding(28)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
