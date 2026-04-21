import SwiftUI

/// Hero strip at the top of the score screen — student name + current-term
/// badge. Behaves gracefully when the parser could not recover either value
/// (new student, malformed HTML) by hiding the badge and falling back to a
/// generic title.
struct StudentHeaderCard: View {
    @Environment(AppState.self) private var appState

    let student: String
    let currentTerm: String

    var body: some View {
        HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: "graduationcap.fill")
                .font(.title2)
                .foregroundStyle(Color(hex: 0x4ECDC4))
                .frame(width: 44, height: 44)
                .background(Color(hex: 0x4ECDC4).opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(student.isEmpty ? "歷年成績" : student)
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
        guard code.count == 4 else { return code }
        let year = String(code.prefix(3))
        let semester = String(code.suffix(1))
        let label = semester == "1" ? "上" : semester == "2" ? "下" : semester
        return "\(year) 學年度 · \(label)學期"
    }
}
