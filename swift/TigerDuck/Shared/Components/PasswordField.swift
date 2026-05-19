import SwiftUI
import UIKit

/// Password input with a trailing eye toggle.
///
/// Backed by a single `UITextField` via `UIViewRepresentable` so toggling
/// secure entry does not tear down the first responder. The keyboard stays
/// up across visibility toggles and across taps to/from this field.
struct PasswordField<Field: Hashable>: View {
    let placeholder: String
    @Binding var text: String
    var focusBinding: FocusState<Field?>.Binding
    let focusValue: Field
    var returnKeyType: UIReturnKeyType = .go
    var onSubmit: () -> Void = {}

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 4) {
            _PasswordTextField(
                placeholder: placeholder,
                text: $text,
                isSecure: !isVisible,
                isFocused: Binding(
                    get: { focusBinding.wrappedValue == focusValue },
                    set: { newValue in
                        if newValue {
                            focusBinding.wrappedValue = focusValue
                        } else if focusBinding.wrappedValue == focusValue {
                            focusBinding.wrappedValue = nil
                        }
                    }
                ),
                returnKeyType: returnKeyType,
                onSubmit: onSubmit
            )

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible
                ? String(localized: "password_hide")
                : String(localized: "password_show"))
        }
    }
}

private struct _PasswordTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    @Binding var isFocused: Bool
    let returnKeyType: UIReturnKeyType
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.isSecureTextEntry = isSecure
        field.keyboardType = .asciiCapable
        field.textContentType = .password
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = returnKeyType
        field.clearButtonMode = .never
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self

        if field.placeholder != placeholder { field.placeholder = placeholder }
        if field.returnKeyType != returnKeyType { field.returnKeyType = returnKeyType }
        if field.text != text { field.text = text }

        if field.isSecureTextEntry != isSecure {
            applySecureTextEntry(isSecure, on: field)
        }

        // Mirror @FocusState → UITextField for the BECOME direction only.
        //
        // We deliberately do not call `resignFirstResponder` from here. UIKit
        // already transfers first responder automatically when another control
        // is tapped or programmatically focused, and trying to resign in
        // response to a transient `focusedField == nil` (which SwiftUI emits
        // during a tap-driven focus migration from a sibling field) is what
        // produced the brief keyboard collapse-and-expand on field switches.
        if isFocused {
            DispatchQueue.main.async { [weak field] in
                guard let field, !field.isFirstResponder else { return }
                _ = field.becomeFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        // Without this, the wrapped `UITextField` reports `noIntrinsicMetric`
        // for width and SwiftUI's HStack will not necessarily hand it the
        // remaining horizontal space the way it does for a native `TextField`.
        // The field then collapses to ~zero width and taps never land on it.
        let intrinsicHeight = uiView.intrinsicContentSize.height
        let height = intrinsicHeight > 0 ? intrinsicHeight : 30
        let width = proposal.width ?? UIView.noIntrinsicMetric
        return CGSize(width: width, height: height)
    }

    /// Flip `isSecureTextEntry` on the live field without losing typed text
    /// or moving first responder.
    ///
    /// Apple's documented behaviour is that toggling `isSecureTextEntry`
    /// while text is being entered clears the field. We work around it by
    /// reassigning `text` (nil → saved value), which leaves the field in
    /// a stable internal state without dropping first responder, then we
    /// restore the caret/selection by character offset (the saved
    /// `UITextRange` becomes invalid the moment `text` is reassigned).
    private func applySecureTextEntry(_ isSecure: Bool, on field: UITextField) {
        let savedText = field.text
        let savedOffsets: (start: Int, end: Int)? = {
            guard let range = field.selectedTextRange else { return nil }
            let start = field.offset(from: field.beginningOfDocument, to: range.start)
            let end = field.offset(from: field.beginningOfDocument, to: range.end)
            return (start, end)
        }()

        field.isSecureTextEntry = isSecure

        // Only the editing-in-progress path needs the round-trip; if no one
        // is editing, the toggle alone is harmless.
        guard field.isFirstResponder else { return }

        field.text = nil
        field.text = savedText

        guard let savedOffsets,
              let start = field.position(from: field.beginningOfDocument, offset: savedOffsets.start),
              let end = field.position(from: field.beginningOfDocument, offset: savedOffsets.end),
              let restored = field.textRange(from: start, to: end)
        else { return }
        field.selectedTextRange = restored
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: _PasswordTextField

        init(parent: _PasswordTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ sender: UITextField) {
            let newValue = sender.text ?? ""
            if parent.text != newValue { parent.text = newValue }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            // Defer to the next runloop tick for two reasons:
            // 1) Avoid mutating SwiftUI state from inside the UIKit responder
            //    transition stack frame.
            // 2) Sequence our write AFTER SwiftUI's internal bridge for the
            //    previously focused field (which may queue a transient
            //    `focusedField = nil`). FIFO of `DispatchQueue.main.async`
            //    means our write, queued later, wins.
            DispatchQueue.main.async { [weak self, weak textField] in
                guard let self, let textField, textField.isFirstResponder else { return }
                if !self.parent.isFocused { self.parent.isFocused = true }
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // Intentionally do not write `focusedField = nil` here. When a
            // sibling field is taking over, its own SwiftUI focus bridge has
            // already installed the correct value; writing nil here would
            // race against it and clobber the new focus.
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
