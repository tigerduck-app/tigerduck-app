#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailCredentialPrefillTests {
    nonisolated static let studentID = "B10000000"
    nonisolated static let ntustPassword = "prefill-fixture-ntust"
    static let typedPassword = "prefill-fixture-typed"
    static let overrideSuffix = "@example.com"

    static func fields(
        storedID: String? = studentID,
        storedPassword: String? = ntustPassword,
        currentID: String = "",
        currentPassword: String = "",
        isOverridden: Bool = false,
        lastRejectedPassword: String? = nil,
        domainSuffix: String = ""
    ) -> MailCredentialPrefill.Fields {
        MailCredentialPrefill.fields(
            storedID: storedID,
            storedPassword: storedPassword,
            currentID: currentID,
            currentPassword: currentPassword,
            isOverridden: isOverridden,
            lastRejectedPassword: lastRejectedPassword,
            domainSuffix: domainSuffix
        )
    }

    @Test("Empty fields are seeded from the NTUST account")
    func emptyFieldsTakeTheStoredCredentials() {
        let fields = Self.fields()
        #expect(fields.id == Self.studentID)
        #expect(fields.password == Self.ntustPassword)
    }

    @Test("Signed out of NTUST there is nothing to seed")
    func nothingStoredSeedsNothing() {
        let fields = Self.fields(storedID: nil, storedPassword: nil)
        #expect(fields == MailCredentialPrefill.Fields(id: "", password: ""))
    }

    @Test("Seeding a password sends nothing to the server")
    func theDecisionNeverSignsIn() async {
        let h = MailAccountManagerTests.harness()
        for _ in 0..<3 {
            _ = Self.fields()
        }
        #expect(await h.fake.calls.isEmpty)
        #expect(!h.manager.isLoggedIn)
        #expect(h.manager.loginError == nil)
    }

    @Test("An override offers the server's own @domain and no password at all")
    func anOverrideSeedsNoSchoolCredentials() {
        let fields = Self.fields(isOverridden: true, domainSuffix: Self.overrideSuffix)
        #expect(fields.id == Self.overrideSuffix)
        #expect(fields.password.isEmpty)
    }

    @Test("An override turned on mid-session takes the already-prefilled credentials back out")
    func anOverrideTurnedOnMidSessionClearsWhatWasAlreadySeeded() {
        let seeded = Self.fields()
        #expect(seeded.password == Self.ntustPassword)

        let afterOverride = Self.fields(
            currentID: seeded.id,
            currentPassword: seeded.password,
            isOverridden: true,
            domainSuffix: Self.overrideSuffix
        )
        #expect(afterOverride.id == Self.overrideSuffix)
        #expect(afterOverride.password.isEmpty)
    }

    @Test("A re-cased prefilled ID still counts as prefilled")
    func aRecasedPrefilledIDIsStillReplaced() {
        let fields = Self.fields(
            currentID: " b10000000 ",
            currentPassword: Self.ntustPassword,
            isOverridden: true,
            domainSuffix: Self.overrideSuffix
        )
        #expect(fields.id == Self.overrideSuffix)
        #expect(fields.password.isEmpty)
    }

    @Test("An override leaves a half-typed username alone, but never keeps a password")
    func anOverrideKeepsATypedUsername() {
        let fields = Self.fields(
            currentID: "someone@example.com",
            currentPassword: Self.typedPassword,
            isOverridden: true,
            domainSuffix: Self.overrideSuffix
        )
        #expect(fields.id == "someone@example.com")
        #expect(fields.password.isEmpty)
    }

    @Test("A half-typed ID and password survive a re-seed")
    func typedValuesAreNeverOverwritten() {
        let fields = Self.fields(currentID: "B999", currentPassword: Self.typedPassword)
        #expect(fields.id == "B999")
        #expect(fields.password == Self.typedPassword)
    }

    @Test("Each field is judged on its own")
    func anEmptyPasswordIsSeededBesideATypedID() {
        let fields = Self.fields(currentID: "B999")
        #expect(fields.id == "B999")
        #expect(fields.password == Self.ntustPassword)
    }

    @Test("A rejected password is not seeded again")
    func aRejectedPasswordIsNeverReoffered() {
        let fields = Self.fields(lastRejectedPassword: Self.ntustPassword)
        #expect(fields.id == Self.studentID)
        #expect(fields.password.isEmpty)
    }

    @Test("Some other rejected password does not suppress the seed")
    func anUnrelatedRejectionDoesNotSuppressTheSeed() {
        let fields = Self.fields(lastRejectedPassword: Self.typedPassword)
        #expect(fields.password == Self.ntustPassword)
    }

    @Test("A password typed after a rejection is kept, not cleared")
    func aTypedPasswordSurvivesARejection() {
        let fields = Self.fields(
            currentPassword: Self.typedPassword,
            lastRejectedPassword: Self.ntustPassword
        )
        #expect(fields.password == Self.typedPassword)
    }

    @Test("A rejected sign-in is remembered, and then never re-seeded")
    func aRejectionIsRememberedAndBlocksTheNextSeed() async {
        let h = MailAccountManagerTests.harness()
        await h.fake.update { $0.loginError = .authenticationFailed }
        await h.manager.login(studentID: Self.studentID, password: Self.ntustPassword)

        #expect(h.manager.loginError == .credentials)
        #expect(h.manager.lastRejectedPassword == Self.ntustPassword)
        #expect(!h.manager.authFailed)

        let fields = Self.fields(lastRejectedPassword: h.manager.lastRejectedPassword)
        #expect(fields.password.isEmpty)
    }

    @Test("Only a rejection is remembered — an unreachable server is not one")
    func aTransportFailureIsNotARejection() async {
        let h = MailAccountManagerTests.harness()
        await h.fake.update { $0.loginError = .unreachable }
        await h.manager.login(studentID: Self.studentID, password: Self.ntustPassword)

        #expect(h.manager.loginError == .network)
        #expect(h.manager.lastRejectedPassword == nil)
        #expect(Self.fields(lastRejectedPassword: h.manager.lastRejectedPassword).password == Self.ntustPassword)
    }

    @Test("A sign-in the server accepted forgets the rejection")
    func anAcceptedSignInForgetsTheRejection() async {
        let h = MailAccountManagerTests.harness()
        await h.fake.update { $0.loginError = .authenticationFailed }
        await h.manager.login(studentID: Self.studentID, password: Self.typedPassword)
        #expect(h.manager.lastRejectedPassword == Self.typedPassword)

        await h.fake.update { $0.loginError = nil }
        await h.manager.login(studentID: Self.studentID, password: Self.ntustPassword)
        #expect(h.manager.isLoggedIn)
        #expect(h.manager.lastRejectedPassword == nil)
    }

    @Test("The re-auth sheet does not reopen with a rejected password")
    func theSheetDoesNotReopenWithARejectedPassword() {
        let fields = MailLoginSheet.initialFields(
            storedID: Self.studentID,
            storedPassword: Self.ntustPassword,
            lastRejected: Self.ntustPassword
        )
        #expect(fields.password.isEmpty)
    }
}
#endif
