#if os(iOS)
import SwiftUI

/// The rules the compose screen's recipient field turns typing into bubbles by. Pure, so they
/// can be tested without a view.
nonisolated enum MailRecipientTokens {
    /// Splits what has been typed into the recipients it finishes and what is still being typed.
    ///
    /// `,` and `;` always end a recipient. A space ends one only once what came before it holds
    /// an `@` — so `王大明 <wang@mail.ntust.edu.tw>` can still be typed name first — and never
    /// inside quotes or angle brackets, where it is part of the name or the address.
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
        // A leading space is never the start of an address.
        return (finished, String(current.drop { $0 == " " }))
    }

    /// The field's whole value as the view model keeps it: every recipient, comma-separated.
    static func compose(_ tokens: [String], draft: String) -> String {
        (tokens + [draft.trimmingCharacters(in: .whitespaces)]).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// A value set from outside the field — a reply's prefilled recipients, a draft reopened —
    /// as bubbles. Only `,`/`;` split here: the value is already a list, and a space inside it
    /// belongs to a name.
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

/// A To, Cc or Bcc field that turns each recipient into a bubble as it is typed: `,`, `;`, a
/// space after an address, Return, or leaving the field finishes one. A bubble the send would
/// refuse is marked red. Tapping a bubble takes it back into the text to edit; its × removes it.
///
/// The view model still holds the field as one comma-separated string (`text`), so sending,
/// validation, drafts and reply prefill are unchanged.
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
            FlowLayout(spacing: 4, lineSpacing: 6) {
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
        .onTapGesture { focus.wrappedValue = field }
        .onAppear { load(text) }
        .onChange(of: text) { _, value in
            // Only a value this field did not write — a reply's recipients arriving, a reset.
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

    /// A capsule on one line — the radius is half a one-line bubble's height — that stays a
    /// rounded box, rather than a stretched pill, when a long address wraps.
    private static var bubbleShape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    private func bubble(_ token: String, at index: Int) -> some View {
        let valid = MailComposeViewModel.sendableAddress(token) != nil
        return HStack(spacing: 4) {
            // Wraps rather than truncating, so a long address is never shown cut short.
            Text(verbatim: token)
                .fixedSize(horizontal: false, vertical: true)
                .typesettingLanguage(MailRecipient.unhyphenatedLanguage)
            Button {
                tokens.remove(at: index)
                publish()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: "\(token) ×"))
        }
        .font(TigerDuckTheme.Typography.caption)
        .foregroundStyle(valid ? Color.textPrimary : Color.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(valid ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(Color.red.opacity(0.15)), in: Self.bubbleShape)
        .overlay { if !valid { Self.bubbleShape.strokeBorder(Color.red.opacity(0.6), lineWidth: 1) } }
        .contentShape(Self.bubbleShape)
        .onTapGesture { edit(at: index) }
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

    /// Takes a bubble back into the text, finishing whatever was being typed first.
    private func edit(at index: Int) {
        finishDraft()
        guard tokens.indices.contains(index) else { return }
        draft = tokens.remove(at: index)
        publish()
        focus.wrappedValue = field
    }
}
#endif
