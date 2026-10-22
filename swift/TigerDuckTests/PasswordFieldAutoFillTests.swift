#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct PasswordFieldAutoFillTests {
    enum Write: CaseIterable {
        case insert, replace
    }

    @MainActor
    @Observable
    final class Credentials {
        var account = ""
        var password = ""
        var canSignIn: Bool { !account.isEmpty && !password.isEmpty }
    }

    private struct SignInForm: View {
        enum Field: Hashable { case account, password }

        @Bindable var credentials: Credentials
        @FocusState private var focusedField: Field?

        var body: some View {
            Form {
                TextField("Account", text: $credentials.account)
                    .textContentType(.username)
                    .focused($focusedField, equals: .account)
                PasswordField(
                    placeholder: "Password",
                    text: $credentials.password,
                    focusBinding: $focusedField,
                    focusValue: .password
                )
                Button("Sign in") {}
                    .disabled(!credentials.canSignIn)
            }
        }
    }

    private struct Hosted {
        let window: UIWindow
        let account: UITextField
        let password: UITextField
        let decoy: UITextField
    }

    @Test(arguments: Write.allCases)
    func autoFilledPasswordReachesTheBinding(write: Write) async throws {
        try await withCaptureProtectionOn {
            let credentials = Credentials()
            let form = try await host(credentials)

            form.account.insertText("B11000000")
            switch write {
            case .insert:
                form.decoy.insertText("secret")
            case .replace:
                let all = try #require(form.decoy.textRange(from: form.decoy.beginningOfDocument, to: form.decoy.endOfDocument))
                form.decoy.replace(all, withText: "secret")
            }

            #expect(form.password.text == "secret", "the field the user sees shows the password")
            #expect(form.decoy.text?.isEmpty ?? true, "nothing is left in the decoy to show behind the field")
            #expect(credentials.password == "secret")
            #expect(credentials.canSignIn)
            form.window.isHidden = true
        }
    }

    @Test func typedPasswordStillReachesTheBinding() async throws {
        try await withCaptureProtectionOn {
            let credentials = Credentials()
            let form = try await host(credentials)

            for character in "B11000000" { form.account.insertText(String(character)) }
            _ = form.password.becomeFirstResponder()
            for character in "secrets" { form.password.insertText(String(character)) }
            form.password.deleteBackward()

            #expect(credentials.password == "secret")
            #expect(credentials.canSignIn)
            form.window.isHidden = true
        }
    }

    private func withCaptureProtectionOn(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let key = ScreenCaptureProtectionDebugFlag.userDefaultsKey
        let saved = defaults.object(forKey: key)
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(false, forKey: key)
        try await body()
    }

    private func host(_ credentials: Credentials) async throws -> Hosted {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: SignInForm(credentials: credentials))
        window.makeKeyAndVisible()
        try await waitUntil { window.descendants(ofType: UITextField.self).contains { $0.textContentType == .password } }

        let fields = window.descendants(ofType: UITextField.self)
        return Hosted(
            window: window,
            account: try #require(fields.first { $0.textContentType == .username }),
            password: try #require(fields.first { $0.textContentType == .password }),
            decoy: try #require(fields.first { !$0.canBecomeFirstResponder }, "the capture wrapper's field")
        )
    }
}
#endif
