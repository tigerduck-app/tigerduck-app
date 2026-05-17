import SwiftUI

struct LoginSheet: View {
    let title: String
    let subtitle: String?
    let usernamePlaceholder: String
    let passwordPlaceholder: String
    let isLoggingIn: Bool
    let loginError: String?
    let onLogin: (String, String) -> Void
    let onDismiss: () -> Void

    @State private var username: String
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    init(
        title: String,
        subtitle: String? = nil,
        usernamePlaceholder: String,
        passwordPlaceholder: String,
        initialUsername: String = "",
        isLoggingIn: Bool,
        loginError: String?,
        onLogin: @escaping (String, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.usernamePlaceholder = usernamePlaceholder
        self.passwordPlaceholder = passwordPlaceholder
        self.isLoggingIn = isLoggingIn
        self.loginError = loginError
        self.onLogin = onLogin
        self.onDismiss = onDismiss
        _username = State(initialValue: initialUsername)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(usernamePlaceholder, text: $username)
                        .keyboardType(.asciiCapable)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                    PasswordField(
                        placeholder: passwordPlaceholder,
                        text: $password,
                        focusBinding: $focusedField,
                        focusValue: .password,
                        onSubmit: { submitIfReady() }
                    )
                } footer: {
                    if let subtitle {
                        Label(subtitle, systemImage: "info.circle")
                            .font(.caption)
                    }
                }

                if let loginError {
                    Section {
                        Label(loginError, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        submitIfReady()
                    } label: {
                        HStack {
                            Spacer()
                            if isLoggingIn {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 6)
                            }
                            Text(String(localized: "action_login"))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isLoggingIn)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { onDismiss() }
                }
            }
            .onAppear {
                focusedField = username.isEmpty ? .username : .password
            }
            .interactiveDismissDisabled(isLoggingIn)
        }
        .presentationDetents([.medium])
    }

    private func submitIfReady() {
        guard !username.isEmpty, !password.isEmpty, !isLoggingIn else { return }
        focusedField = nil
        onLogin(username, password)
    }
}
