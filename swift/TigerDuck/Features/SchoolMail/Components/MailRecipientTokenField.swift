#if os(iOS)
import SwiftUI

nonisolated enum MailRecipientTokens {
    static func consume(_ typed: String) -> (finished: [String], remainder: String) {
        var finished: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for character in typed {
            if character == "\"" { inQuotes.toggle() }
            if character == "<", !inQuotes { inAngle = true }
            if character == ">", !inQuotes { inAngle = false }
            let separates = !inQuotes && !inAngle
                && (character == "," || character == ";" || (character == " " && current.contains("@")))
            if separates {
                if let token = current.trimmingCharacters(in: .whitespaces).mailNonEmpty { finished.append(token) }
                current = ""
            } else {
                current.append(character)
            }
        }
        return (finished, String(current.drop { $0 == " " }))
    }

    static func compose(_ tokens: [String], draft: String) -> String {
        (tokens + [draft.trimmingCharacters(in: .whitespaces)]).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func tokens(of value: String) -> [String] {
        let (finished, remainder) = consumeSeparatorsOnly(value)
        return finished + [remainder].compactMap { $0.trimmingCharacters(in: .whitespaces).mailNonEmpty }
    }

    private static func consumeSeparatorsOnly(_ value: String) -> (finished: [String], remainder: String) {
        var finished: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for character in value {
            if character == "\"" { inQuotes.toggle() }
            if character == "<", !inQuotes { inAngle = true }
            if character == ">", !inQuotes { inAngle = false }
            if (character == "," || character == ";") && !inQuotes && !inAngle {
                if let token = current.trimmingCharacters(in: .whitespaces).mailNonEmpty { finished.append(token) }
                current = ""
            } else {
                current.append(character)
            }
        }
        return (finished, current)
    }
}

struct MailRecipientTokenField<Focus: Hashable>: View {
    let title: String
    @Binding var text: String
    let focus: FocusState<Focus?>.Binding
    let field: Focus

    @State private var tokens: [String] = []
    @State private var draft = ""

    var body: some View {
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

    private static var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
    }

    private func bubble(_ token: String, at index: Int) -> some View {
        let valid = MailComposeViewModel.sendableAddress(token) != nil
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

    private func edit(at index: Int) {
        finishDraft()
        guard tokens.indices.contains(index) else { return }
        draft = tokens.remove(at: index)
        publish()
        focus.wrappedValue = field
    }
}
#endif
