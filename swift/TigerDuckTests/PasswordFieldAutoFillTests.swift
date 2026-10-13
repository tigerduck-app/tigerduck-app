#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// AutoFill fills a sign-in form through each field's `insertText(_:)`, or `replace(_:withText:)`
/// when the field has text, and the password field it picks next to the account field is the
/// secure decoy `.screenCaptureProtected` hosts `PasswordField` on: its search for a form's fields
/// does not look inside a text field. These tests write into the decoy as AutoFill does and check
/// the password reaches the binding, which the sign-in forms' Sign in button waits for.
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
        /// When `LoginSheet` enables Sign in, apart from a sign-in already running.
        var canSignIn: Bool { !account.isEmpty && !password.isEmpty }
    }

    /// `LoginSheet`'s form as AutoFill sees it, without the `AppState` the sheet needs.
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

    /// Runs `body` with the capture wrapper on, which Settings → Developer can store as off in the
    /// simulator, and puts the stored value back afterwards.
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
        // The password field joins the window once the capture wrapper has laid out its canvas.
        try await waitUntil { Self.textFields(in: window).contains { $0.textContentType == .password } }

        let fields = Self.textFields(in: window)
        return Hosted(
            window: window,
            account: try #require(fields.first { $0.textContentType == .username }),
            password: try #require(fields.first { $0.textContentType == .password }),
            decoy: try #require(fields.first { !$0.canBecomeFirstResponder }, "the capture wrapper's field")
        )
    }

    private static func textFields(in view: UIView) -> [UITextField] {
        view.subviews.flatMap { [$0 as? UITextField].compactMap { $0 } + textFields(in: $0) }
    }
}
#endif
