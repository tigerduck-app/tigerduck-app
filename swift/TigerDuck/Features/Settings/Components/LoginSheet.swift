import SwiftUI

struct LoginSheet: View {
    /// A link under the fields, e.g. School Mail's "Forgot your password? Go to
    /// mail.ntust.edu.tw".
    /// Opens the way bulletins do: in-app when the user prefers it, otherwise the browser.
    struct FooterLink {
        let title: String
        let url: URL
    }

    let title: String
    let subtitle: String?
    let usernamePlaceholder: String
    let passwordPlaceholder: String
    let isLoggingIn: Bool
    let loginError: String?
    let onLogin: (String, String) -> Void
    let onDismiss: () -> Void
    let footerLink: FooterLink?

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var inAppURL: URL?

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
        footerLink: FooterLink? = nil,
        onLogin: @escaping (String, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.usernamePlaceholder = usernamePlaceholder
        self.passwordPlaceholder = passwordPlaceholder
        self.isLoggingIn = isLoggingIn
        self.loginError = loginError
        self.footerLink = footerLink
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
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                        if let subtitle {
                            Label(subtitle, systemImage: "info.circle")
                                .font(.caption)
                        }
                        if let footerLink {
                            Button(footerLink.title) { open(footerLink.url) }
                                .font(.caption)
                        }
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
                        LoadingButtonLabel(isLoading: isLoggingIn) {
                            HStack {
                                Spacer()
                                Text(String(localized: "action_sign_in"))
                                    .fontWeight(.semibold)
                                Spacer()
                            }
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
            #if os(iOS)
            .sheet(isPresented: Binding(get: { inAppURL != nil }, set: { if !$0 { inAppURL = nil } })) {
                if let inAppURL {
                    InAppBrowserView(url: inAppURL).ignoresSafeArea()
                }
            }
            #endif
        }
        .presentationDetents([.medium])
    }

    private func submitIfReady() {
        guard !username.isEmpty, !password.isEmpty, !isLoggingIn else { return }
        #if canImport(UIKit)
        UIApplication.dismissKeyboard()
        #endif
        focusedField = nil
        onLogin(username, password)
    }

    private func open(_ url: URL) {
        #if os(iOS)
        if appState.browserPreference == .inApp {
            inAppURL = url
            return
        }
        #endif
        openURL(url)
    }
}
