import SwiftUI
import UIKit

/// Password input with a trailing eye toggle.
///
/// Backed by a single `UITextField` via `UIViewRepresentable` that stays
/// permanently in `isSecureTextEntry = true`. This is load-bearing: iOS
/// only puts the system keyboard into "passcode mode" (no key-preview
/// popovers, no QuickType bar, *and excluded from screen recording /
/// mirroring*) while the active first responder has secure entry on. If
/// we flipped it off to show cleartext, the keyboard would become a
/// normal keyboard mid-session and start leaking each keystroke through
/// the magnifier popovers to anyone recording the screen.
///
/// To still let the user reveal what they typed, the cleartext rides on
/// top as a SwiftUI `Text` overlay (with its own secure-canvas wrap so
/// it stays out of screenshots). Underneath, the real field's dots are
/// painted with `textColor = .clear` while the overlay is showing — the
/// field still owns input, the keyboard never leaves passcode mode, and
/// the cleartext is what the user sees.
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
            ZStack(alignment: .leading) {
                _PasswordTextField(
                    placeholder: placeholder,
                    text: $text,
                    // When the cleartext overlay is shown, hide the
                    // underlying dots so the overlay is what the user
                    // reads. `isSecureTextEntry` itself never changes.
                    hidesDots: isVisible,
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

                if isVisible, !text.isEmpty {
                    // Caret painted at the end of the cleartext. The
                    // native UITextField caret is hidden in reveal mode
                    // (see `applyDotsVisibility`) because bullet glyphs
                    // are wider than typical password characters, so the
                    // native caret floats off to the right of the visible
                    // text. Drawn always-on (no blink) because TimelineView
                    // can stall inside a UIHostingController hosted under
                    // a UITextField's secure canvas.
                    HStack(spacing: 2) {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2, height: 20)
                        Spacer(minLength: 0)
                    }
                    .allowsHitTesting(false)
                    .screenCaptureProtected(true)
                }
            }

            Button {
                isVisible.toggle()
            } label: {
                // Open eye = password is currently visible; eye.slash =
                // currently hidden. (Mirror-the-state reading, not
                // tap-to-action.)
                Image(systemName: isVisible ? "eye" : "eye.slash")
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
    let hidesDots: Bool
    @Binding var isFocused: Bool
    let returnKeyType: UIReturnKeyType
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        // Permanently secure — see the doc comment on PasswordField for
        // why this never toggles.
        field.isSecureTextEntry = true
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
        applyDotsVisibility(hidesDots, on: field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self

        if field.placeholder != placeholder { field.placeholder = placeholder }
        if field.returnKeyType != returnKeyType { field.returnKeyType = returnKeyType }
        if field.text != text { field.text = text }

        applyDotsVisibility(hidesDots, on: field)

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

    /// Hide or restore the dot glyphs without touching `isSecureTextEntry`.
    /// Also hides the native caret while the cleartext overlay is showing
    /// (the native caret sits past the end of the bullets, which are wider
    /// than typical password characters — making it look detached from the
    /// visible cleartext). The overlay paints its own caret in the right
    /// place via `CleartextCaret`.
    private func applyDotsVisibility(_ hide: Bool, on field: UITextField) {
        let textTarget: UIColor = hide ? .clear : .label
        if field.textColor != textTarget { field.textColor = textTarget }
        let caretTarget: UIColor = hide ? .clear : .tintColor
        if field.tintColor != caretTarget { field.tintColor = caretTarget }
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
