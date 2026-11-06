#if os(iOS)
import SwiftUI

nonisolated enum MailRecipientTokens {
    static func consume(_ typed: String) -> (finished: [String], remainder: String) {
        let pieces = MailAddress.splitTopLevel(typed) { character, current in
            character == "," || character == ";" || (character == " " && current.contains("@"))
        }
        return (pieces.dropLast().compactMap(trimmed), String(pieces.last?.drop { $0 == " " } ?? ""))
    }

    static func compose(_ tokens: [String], draft: String) -> String {
        (tokens + [draft.trimmingCharacters(in: .whitespaces)]).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func tokens(of value: String) -> [String] {
        MailAddress.splitTopLevel(value).compactMap(trimmed)
    }

    private static func trimmed(_ token: String) -> String? {
        token.trimmingCharacters(in: .whitespaces).mailNonEmpty
    }
}

struct MailRecipientTokenField<Focus: Hashable>: View {
    let title: String
    @Binding var text: String
    let focus: FocusState<Focus?>.Binding
    let field: Focus
    let suggest: (String) -> [MailAddress]

    @State private var tokens: [String] = []
    @State private var draft = ""

    var body: some View {
        row
        let matches = focus.wrappedValue == field ? suggest(draft) : []
        if !matches.isEmpty { suggestions(matches) }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.xs) {
            Text(title)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: TigerDuckTheme.Spacing.xs, lineSpacing: 6) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                    bubble(token, at: index)
                }
                TextField("", text: $draft)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(focus, equals: field)
                    .onSubmit(finishDraft)
                    .frame(minWidth: 120)
                    .accessibilityLabel(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .simultaneousTapGesture { focus.wrappedValue = field }
        .onAppear { load(text) }
        .onChange(of: text) { _, value in
            if value != MailRecipientTokens.compose(tokens, draft: draft) { load(value) }
        }
        .onChange(of: draft) { _, typed in
            let (finished, remainder) = MailRecipientTokens.consume(typed)
            if !finished.isEmpty || remainder != typed {
                tokens += finished
                draft = remainder
            }
            publish()
        }
        .onChange(of: focus.wrappedValue) { _, now in
            if now != field { finishDraft() }
        }
    }

    private func suggestions(_ matches: [MailAddress]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.address) { index, address in
                if index > 0 { Divider() }
                Button { pick(address) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(highlighted(address.name ?? address.address))
                        if address.name != nil {
                            Text(highlighted(address.address))
                                .font(.subheadline)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    .typesettingLanguage(MailRecipient.unhyphenatedLanguage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, TigerDuckTheme.Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("a11y_school_mail_recipient_suggestions"))
    }

    private func highlighted(_ text: String) -> AttributedString {
        var shown = AttributedString(text)
        let typed = draft.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, let match = shown.range(of: typed, options: [.caseInsensitive, .widthInsensitive]) {
            shown[match].inlinePresentationIntent = .stronglyEmphasized
        }
        return shown
    }

    private static var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
    }

    private func bubble(_ token: String, at index: Int) -> some View {
        let valid = MailRecipients.sendableAddress(token) != nil
        return HStack(spacing: 0) {
            Text(verbatim: token)
                .fixedSize(horizontal: false, vertical: true)
                .typesettingLanguage(MailRecipient.unhyphenatedLanguage)
                .padding(.leading, TigerDuckTheme.Spacing.sm)
                .padding(.trailing, TigerDuckTheme.Spacing.xs)
                .padding(.vertical, TigerDuckTheme.Spacing.xs)
                .scrollSafeTapAction { edit(at: index) }
            Button {
                tokens.remove(at: index)
                publish()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .padding(.trailing, TigerDuckTheme.Spacing.sm)
                    .padding(.vertical, TigerDuckTheme.Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: "\(token) ×"))
        }
        .font(TigerDuckTheme.Typography.caption)
        .foregroundStyle(valid ? Color.textPrimary : Color.red)
        .background(valid ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(Color.red.opacity(0.15)), in: Self.bubbleShape)
        .overlay { if !valid { Self.bubbleShape.strokeBorder(Color.red.opacity(0.6), lineWidth: 1) } }
    }

    private func load(_ value: String) {
        tokens = MailRecipientTokens.tokens(of: value)
        draft = ""
    }

    private func publish() {
        let composed = MailRecipientTokens.compose(tokens, draft: draft)
        if text != composed { text = composed }
    }

    private func finishDraft() {
        guard let token = draft.trimmingCharacters(in: .whitespaces).mailNonEmpty else { return }
        tokens.append(token)
        draft = ""
        publish()
    }

    private func pick(_ address: MailAddress) {
        tokens.append(MailRecipients.format(address))
        draft = ""
        publish()
        focus.wrappedValue = field
    }

    private func edit(at index: Int) {
        finishDraft()
        guard tokens.indices.contains(index) else { return }
        draft = tokens.remove(at: index)
        publish()
        focus.wrappedValue = field
    }
}
#endif
