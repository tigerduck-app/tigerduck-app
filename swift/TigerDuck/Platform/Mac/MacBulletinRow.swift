#if os(macOS)
import SwiftUI

struct MacBulletinRow: View {
    let bulletin: BulletinAPI.BulletinSummary
    let isRead: Bool
    let orgLabel: (String) -> String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(.tint.opacity(isRead ? 0 : 1))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(bulletin.displayTitle)
                    .font(.system(.body, design: .default).weight(isRead ? .regular : .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let org = bulletin.canonicalOrg, !org.isEmpty {
                        Text(orgLabel(org))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(.quaternary)
                            )
                    }
                    if let posted = bulletin.postedAt {
                        Text(posted, format: .dateTime.month().day())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let summary = bulletin.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
