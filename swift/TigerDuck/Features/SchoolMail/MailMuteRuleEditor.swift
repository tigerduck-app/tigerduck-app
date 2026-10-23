#if os(iOS)
import SwiftUI

extension MailMuteRule.Field {
    var title: String {
        switch self {
        case .from: String(localized: "school_mail_filter_field_from")
        case .toOrCc: String(localized: "school_mail_filter_field_to_cc")
        case .subject: String(localized: "school_mail_filter_field_subject")
        }
    }
}

extension MailMuteRule.Operator {
    var title: String {
        switch self {
        case .contains: String(localized: "school_mail_filter_op_contains")
        case .is: String(localized: "school_mail_filter_op_is")
        }
    }
}

extension MailMutePreset {
    var title: String {
        switch self {
        case .bulletin: String(localized: "school_mail_filter_preset_bulletin")
        case .moodleSubmission: String(localized: "school_mail_filter_preset_moodle_submission")
        }
    }
}

/// Colors are set outright: a `List` button tints its whole label otherwise.
struct MailMuteRuleRow: View {
    let rule: MailMuteRule
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.xs) {
            Text(rule.field.title)
            Text(rule.op.title)
            Text(rule.value)
                .font(.subheadline.monospaced())
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
        }
        .foregroundStyle(Color.secondary)
    }
}

struct MailMuteRuleSheet: View {
    let onSave: (MailMuteRule) -> Void
    @State private var rule: MailMuteRule
    /// Kept from the opening, so a saved new rule keeps its title while the sheet closes.
    @State private var isNew: Bool
    @Environment(\.dismiss) private var dismiss

    init(rule: MailMuteRule, isNew: Bool, onSave: @escaping (MailMuteRule) -> Void) {
        self.onSave = onSave
        _rule = State(initialValue: rule)
        _isNew = State(initialValue: isNew)
    }

    static func canSave(_ rule: MailMuteRule) -> Bool {
        !rule.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    Picker(selection: $rule.field) {
                        ForEach(MailMuteRule.Field.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        EmptyView()
                    }
                    .fixedSize()
                    Spacer()
                    Picker(selection: $rule.op) {
                        ForEach(MailMuteRule.Operator.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        EmptyView()
                    }
                    .fixedSize()
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                TextField(rule.field.title, text: $rule.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(isNew ? String(localized: "school_mail_filter_add") : String(localized: "school_mail_filter_edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? String(localized: "action_add") : String(localized: "action_done")) {
                        var saved = rule
                        saved.value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(!Self.canSave(rule))
                }
            }
        }
    }
}

struct MailQuietDaysView: View {
    @Binding var weekdays: Set<Int>

    /// `Calendar` weekday numbers, Sunday first as in the Clock app's Repeat list.
    private static var days: [(weekday: Int, title: String)] {
        [
            (1, String(localized: "weekday_sun_caption")), (2, String(localized: "weekday_mon_caption")),
            (3, String(localized: "weekday_tue_caption")), (4, String(localized: "weekday_wed_caption")),
            (5, String(localized: "weekday_thu_caption")), (6, String(localized: "weekday_fri_caption")),
            (7, String(localized: "weekday_sat_caption")),
        ]
    }

    /// The last selected day stays on: quiet hours on no day would quiet nothing.
    static func toggling(_ weekday: Int, in weekdays: Set<Int>) -> Set<Int> {
        guard weekdays.contains(weekday) else { return weekdays.union([weekday]) }
        return weekdays.count > 1 ? weekdays.subtracting([weekday]) : weekdays
    }

    static func summary(_ weekdays: Set<Int>) -> String {
        if weekdays.count == 7 { return String(localized: "school_mail_quiet_hours_every_day") }
        return days.filter { weekdays.contains($0.weekday) }.map(\.title).joined(separator: " ")
    }

    var body: some View {
        List {
            ForEach(Self.days, id: \.weekday) { day in
                Button {
                    weekdays = Self.toggling(day.weekday, in: weekdays)
                } label: {
                    HStack {
                        Text(day.title).foregroundStyle(Color.primary)
                        Spacer()
                        if weekdays.contains(day.weekday) {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityAddTraits(weekdays.contains(day.weekday) ? .isSelected : [])
            }
        }
        .navigationTitle(String(localized: "school_mail_quiet_hours_days"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
