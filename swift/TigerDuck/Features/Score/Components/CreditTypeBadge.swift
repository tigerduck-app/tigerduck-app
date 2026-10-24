import SwiftUI

struct CreditTypeBadge: View {
    let creditType: CreditType

    var body: some View {
        if let payload = descriptor {
            Text(payload.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(payload.color.opacity(0.18), in: Capsule())
                .foregroundStyle(payload.color)
        }
    }

    private var descriptor: (label: String, color: Color)? {
        switch creditType {
        case .normal, .unknown:
            return nil
        case .educationProgram:
            return (String(localized: "score_credit_type_education_program_short"), TigerDuckTheme.Tint.purple)
        case .notCounted:
            return (String(localized: "score_credit_type_not_counted_short"), TigerDuckTheme.Tint.grey)
        case .notRequired:
            return (String(localized: "score_credit_type_not_required_short"), TigerDuckTheme.Tint.orange)
        case .notEarned:
            return (String(localized: "score_credit_type_not_earned_short"), TigerDuckTheme.Tint.red)
        }
    }
}
