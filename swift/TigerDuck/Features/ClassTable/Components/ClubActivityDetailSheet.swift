import SwiftUI
import TigerDuckCore

struct ClubActivityDetailSheet: View {
    let club: ClubOccurrence
    let policy: VisualStylePolicy

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                DetailSheetHeader(
                    title: club.clubName, subtitle: club.name.isEmpty ? nil : club.name, color: Color(hex: UInt(club.color))
                )
                EmphasisCards {
                    EmphasisCard(
                        label: String(localized: "class_table_club_location_label"),
                        value: club.location.isEmpty ? "—" : club.location,
                        policy: policy
                    )
                    EmphasisCard(
                        label: String(localized: "class_table_club_time_label"),
                        value: TimeRange.text(from: club.start, to: club.end),
                        spokenValue: TimeRange.spoken(from: club.start, to: club.end),
                        policy: policy
                    )
                }
                DetailInfoRow(label: String(localized: "class_table_club_activity_type_label"), value: kindText)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                if !club.content.isEmpty {
                    Divider()
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    Text(club.content)
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                }
            }
            .padding(.top, TigerDuckTheme.Spacing.xl)
            .padding(.bottom, TigerDuckTheme.Spacing.lg)
        }
        .background(Color.backgroundPrimary)
        .presentationDetents([.medium, .large])
    }

    private var kindText: String {
        switch club.kind {
        case .meeting: String(localized: "class_table_club_activity_type_meeting")
        case .event: String(localized: "class_table_club_activity_type_event")
        case .other(let kind): kind
        }
    }
}
