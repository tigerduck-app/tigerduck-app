import SwiftUI

/// Password input with a trailing eye toggle that flips between
/// SecureField (default) and TextField. Autofill / password-AutoFill keep
/// working because both branches set `textContentType(.password)`.
///
/// The visibility flag is owned by the field itself so the parent doesn't
/// need a stash variable just to render the icon. Process backgrounding
/// still wipes the bound `text`, same as a bare SecureField.
struct PasswordField<Field: Hashable>: View {
    let placeholder: String
    @Binding var text: String
    var focusBinding: FocusState<Field?>.Binding
    let focusValue: Field
    var submitLabel: SubmitLabel = .go
    var onSubmit: () -> Void = {}

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if isVisible {
                    TextField(placeholder, text: $text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .keyboardType(.asciiCapable)
            .textContentType(.password)
            .focused(focusBinding, equals: focusValue)
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)

            Button {
                let wasFocused = focusBinding.wrappedValue == focusValue
                isVisible.toggle()
                if wasFocused {
                    // Swapping between SecureField and TextField rebuilds the
                    // input view and drops first responder. Re-assert focus on
                    // the next runloop tick so the keyboard stays up.
                    DispatchQueue.main.async {
                        focusBinding.wrappedValue = focusValue
                    }
                }
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
