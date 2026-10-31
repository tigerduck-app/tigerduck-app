import SwiftUI
import TigerDuckCore

struct StudentHeaderCard: View {
    @Environment(AppState.self) private var appState

    let student: String
    let currentTerm: String

    var body: some View {
        HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: "graduationcap.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(student.isEmpty ? String(localized: "feature_score") : student)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                if !currentTerm.isEmpty {
                    Text(formatTerm(currentTerm))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Spacer()
        }
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func formatTerm(_ code: String) -> String {
        guard case let (year, semester)? = AcademicTerm.displayParts(of: code) else { return code }
        let label = semester == "1"
            ? String(localized: "score_semester_first_short")
            : semester == "2"
                ? String(localized: "score_semester_second_short")
                : semester
        return String(format: String(localized: "score_academic_year_semester"), year, label)
    }
}
