import SwiftUI

/// Small text badge describing how a credit contributes toward graduation.
/// ``CreditType/normal`` is the unmarked default and renders nothing so the
/// list stays visually quiet for the common case.
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
            return (String(localized: "score_credit_type_education_program_short"), Color(hex: 0x9B59B6))
        case .notCounted:
            return (String(localized: "score_credit_type_not_counted_short"), Color(hex: 0x95A5A6))
        case .notRequired:
            return (String(localized: "score_credit_type_not_required_short"), Color(hex: 0xE67E22))
        case .notEarned:
            return (String(localized: "score_credit_type_not_earned_short"), Color(hex: 0xE74C3C))
        }
    }
}
