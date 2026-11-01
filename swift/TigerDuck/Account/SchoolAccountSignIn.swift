import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum SchoolAccountSignIn {
    static func login(studentId: String, password: String, auth: AuthService) async -> Bool {
        auth.status.isLoggingIn = true
        auth.status.loginError = nil
        var schoolStep: SignIn?

        do {
            let normalizedId = AuthService.normalizedStudentId(studentId)
            await auth.signOutCalls?.value
            try Task.checkCancellation()
            if AuthService.replacesStoredAccount(stored: auth.storedStudentId, signingInAs: normalizedId) {
                await auth.signOutStoredAccount?()
                try Task.checkCancellation()
            }
            let signIn = auth.session.signIns.currentSignIn
            schoolStep = signIn

            let success = try await auth.deps.schoolSignIn(normalizedId, password, signIn)
            guard signIn.isCurrent, !Task.isCancelled else {
                auth.status.isLoggingIn = false
                return false
            }

            if success {
                KeychainManager.saveString(key: AppConstants.KeychainKeys.studentId, value: normalizedId)
                KeychainManager.saveString(key: AppConstants.KeychainKeys.password, value: password)
                CourseSelectionService.invalidateEnrolledCoursesCache(for: normalizedId)
                ImportedClassTableStore.shared.accountDidSignIn(studentId: normalizedId, for: signIn)
                #if os(iOS)
                BrowserData.shared.reset()
                #endif
                auth.status.reauthErrorMessage = nil
                auth.markCredentialsChanged()

                await Task {
                    await auth.signInToServices(studentId: normalizedId, password: password, signIn: signIn)
                }.value
            }

            auth.status.isLoggingIn = false
            return success
        } catch where Task.isCancelled || schoolStep.map({ !$0.isCurrent }) == true {
            auth.status.isLoggingIn = false
            return false
        } catch {
            if case SSOLoginError.loginFailed = error {} else {
                AppLogger.captureError(error, context: ["flow": "ntustLogin"])
            }
            auth.status.loginError = error.localizedDescription
            auth.status.isLoggingIn = false
            return false
        }
    }

    static func ensureAuthenticated(auth: AuthService, for signIn: SignIn) async -> Bool {
        guard let studentId = auth.storedStudentId, let password = auth.storedPassword else {
            return false
        }

        if await auth.deps.schoolSessionIsLive(signIn) {
            NTUSTSessionManager.shared.markLoginSuccess(for: signIn)
            auth.status.reauthErrorMessage = nil
            await auth.ensureBackendSignedIn()
            return true
        }

        auth.status.isReauthenticating = true
        auth.status.reauthErrorMessage = nil
        let success = await renewSchoolSession(auth: auth, studentId: studentId, password: password, for: signIn)
        auth.status.isReauthenticating = false

        if !success {
            auth.status.reauthErrorMessage = auth.loginError ?? String(localized: "common_auto_sign_in_failed")
        }
        return success
    }

    private static func renewSchoolSession(
        auth: AuthService, studentId: String, password: String, for signIn: SignIn
    ) async -> Bool {
        auth.status.isLoggingIn = true
        auth.status.loginError = nil
        defer { auth.status.isLoggingIn = false }
        do {
            guard try await auth.deps.renewSchoolSignIn(studentId, password, signIn) else { return false }
        } catch is CancellationError {
            return false
        } catch {
            if case SSOLoginError.loginFailed = error {} else {
                AppLogger.captureError(error, context: ["flow": "ntustReauth"])
            }
            auth.status.loginError = error.localizedDescription
            return false
        }
        auth.noteSchoolSignInRenewed()
        await auth.ensureBackendSignedIn()
        return true
    }
}

enum AuthServiceObservers {
    static func observe(_ center: NotificationCenter, for auth: AuthService) -> [any NSObjectProtocol] {
        var credentialObservers: [any NSObjectProtocol] = []
        #if os(iOS)
        let names: [Notification.Name] = [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        #elseif os(macOS)
        let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification]
        #else
        let names: [Notification.Name] = []
        #endif

        credentialObservers += names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak auth] _ in
                MainActor.assumeIsolated { auth?.revalidateStoredCredentials() }
            }
        }
        #if os(iOS)
        credentialObservers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak auth] _ in
            Task { @MainActor in await auth?.backend.signInAgain() }
        })
        let returnToApp = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let returnToApp = NSApplication.didBecomeActiveNotification
        #endif
        #if os(iOS) || os(macOS)
        credentialObservers.append(center.addObserver(
            forName: returnToApp, object: nil, queue: .main
        ) { [weak auth] _ in
            Task { @MainActor in await auth?.ensureBackendSignedIn() }
        })
        #endif
        credentialObservers.append(center.addObserver(
            forName: SchoolPasswordPosts.storedPasswordPostWaits, object: nil, queue: .main
        ) { [weak auth] _ in
            MainActor.assumeIsolated { auth?.passwordRetry.arm() }
        })
        return credentialObservers
    }
}
