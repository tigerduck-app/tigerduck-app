#if DEBUG && os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// The DEBUG-only developer server override (`Settings → Developer → Email`).
///
/// Everything here works on values rather than on process-wide state: `MailServerConfig` is
/// resolved by a pure function from a settings struct, and every domain rule takes the
/// configuration it should judge against. Nothing in this file writes the real override store
/// or the app's `UserDefaults`, so no test can leave another test pointed at a different mail
/// server — which matters more than usual, since the thing under test is global by nature.
@MainActor
struct MailServerConfigTests {
    static func settings(
        enabled: Bool = true,
        domain: String = "example.com",
        imapHost: String = "imap.example.com",
        imapPort: Int = 143,
        imapScheme: MailTransportScheme = .startTLS,
        smtpHost: String = "smtp.example.com",
        smtpPort: Int = 587,
        smtpScheme: MailTransportScheme = .startTLS
    ) -> MailServerOverrideSettings {
        MailServerOverrideSettings(
            isEnabled: enabled,
            addressDomain: domain,
            imapHost: imapHost,
            imapPort: imapPort,
            imapScheme: imapScheme,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpScheme: smtpScheme
        )
    }

    // MARK: The school configuration, and the override being inert when off

    /// Spec §1.1, still exactly what it says: 993 and 465, both implicit TLS, one host.
    @Test func theSchoolConfigurationIsTheSpecValues() {
        let school = MailServerConfig.school
        #expect(school.imapHost == "mail.ntust.edu.tw")
        #expect(school.smtpHost == "mail.ntust.edu.tw")
        #expect(school.imapPort == 993)
        #expect(school.smtpPort == 465)
        #expect(school.imapScheme == .implicitTLS)
        #expect(school.smtpScheme == .implicitTLS)
        #expect(school.addressDomain == "mail.ntust.edu.tw")
        #expect(school.organizationDomain == "ntust.edu.tw")
        #expect(!school.isOverridden)
    }

    /// The default state of the feature. Also the state the rest of the suite runs in: if this
    /// ever fails, some other test has written the real override store and every domain-rule
    /// expectation in this bundle is being judged against the wrong server.
    @Test func noOverrideIsInForceAndTheEffectiveConfigurationIsTheSchoolOne() {
        #expect(MailServerConfig.effective == .school)
        #expect(!MailServerConfig.effective.isOverridden)
    }

    @Test func anOverrideThatIsOffResolvesToTheSchoolServer() {
        #expect(MailServerConfig.resolve(override: MailServerOverrideSettings()) == .school)
        #expect(MailServerConfig.resolve(override: Self.settings(enabled: false)) == .school)
    }

    /// A switched-on but unfinished override points at the school server rather than at half a
    /// one — and reports `isOverridden == false`, so the page banner never claims an override
    /// that is not actually in force.
    @Test func anIncompleteOverrideResolvesToTheSchoolServer() {
        let incomplete = [
            Self.settings(domain: "   "),
            Self.settings(imapHost: ""),
            Self.settings(smtpHost: " "),
            Self.settings(imapPort: 0),
            Self.settings(smtpPort: 70000),
        ]
        for settings in incomplete {
            #expect(MailServerConfig.resolve(override: settings) == .school)
        }
    }

    // MARK: Resolving a complete override

    @Test func aCompleteOverrideReplacesEveryValue() {
        let resolved = MailServerConfig.resolve(override: Self.settings())
        #expect(resolved.isOverridden)
        #expect(resolved.addressDomain == "example.com")
        #expect(resolved.organizationDomain == "example.com")
        #expect(resolved.imapHost == "imap.example.com")
        #expect(resolved.imapPort == 143)
        #expect(resolved.imapScheme == .startTLS)
        #expect(resolved.smtpHost == "smtp.example.com")
        #expect(resolved.smtpPort == 587)
        #expect(resolved.smtpScheme == .startTLS)
    }

    @Test func hostsAndTheDomainAreTrimmedLowercasedAndTheAtSignIsDropped() {
        let resolved = MailServerConfig.resolve(
            override: Self.settings(domain: " @Example.COM ", imapHost: " IMAP.Example.com ", smtpHost: "SMTP.Example.com")
        )
        #expect(resolved.addressDomain == "example.com")
        #expect(resolved.imapHost == "imap.example.com")
        #expect(resolved.smtpHost == "smtp.example.com")
    }

    /// Plaintext is reachable — it is the point of the "none" scheme — for a host that is not
    /// the school's.
    @Test func plaintextIsAllowedForAHostThatIsNotTheSchools() {
        let resolved = MailServerConfig.resolve(
            override: Self.settings(imapHost: "127.0.0.1", imapPort: 1143, imapScheme: .plaintext,
                                    smtpHost: "127.0.0.1", smtpPort: 1025, smtpScheme: .plaintext)
        )
        #expect(resolved.imapScheme == .plaintext)
        #expect(resolved.smtpScheme == .plaintext)
    }

    // MARK: Requirement 2 — the school host can never be downgraded

    /// Naming the real school host and asking for STARTTLS or no TLS at all is the one thing
    /// this screen must refuse. `MailTLSVerifier` already handles the certificate side (an
    /// unknown host is unpinned but still system-validated, and the school host brings its pins
    /// straight back), but a transport with no TLS handler never reaches the verifier at all,
    /// so the clamp has to happen when the configuration is resolved.
    @Test(arguments: ["mail.ntust.edu.tw", "MAIL.NTUST.EDU.TW", "ntust.edu.tw", "imap.ntust.edu.tw", "api.lib.ntust.edu.tw"])
    func aSchoolHostKeepsImplicitTLSWhateverTheOverrideAsksFor(host: String) {
        for scheme in [MailTransportScheme.startTLS, .plaintext, .implicitTLS] {
            let resolved = MailServerConfig.resolve(
                override: Self.settings(imapHost: host, imapScheme: scheme, smtpHost: host, smtpScheme: scheme)
            )
            #expect(resolved.imapScheme == .implicitTLS)
            #expect(resolved.smtpScheme == .implicitTLS)
        }
    }

    /// The clamp is keyed on the host, so one side of the configuration being the school's does
    /// not drag the other side up with it — and, more to the point, does not let the school side
    /// down.
    @Test func onlyTheSchoolSideOfAMixedConfigurationIsClamped() {
        let resolved = MailServerConfig.resolve(
            override: Self.settings(imapHost: "mail.ntust.edu.tw", imapPort: 143, imapScheme: .plaintext,
                                    smtpHost: "smtp.example.com", smtpPort: 587, smtpScheme: .startTLS)
        )
        #expect(resolved.imapScheme == .implicitTLS)
        #expect(resolved.smtpScheme == .startTLS)
    }

    /// What `isPinnedHost` actually reads. Keyed off the pin table rather than a second copy of
    /// the suffix rule, so the clamp follows the table if it ever changes.
    @Test func pinnedHostsAreTheOnesThePinTableKnows() {
        #expect(MailServerConfig.isPinnedHost("mail.ntust.edu.tw"))
        #expect(MailServerConfig.isPinnedHost("ntust.edu.tw"))
        #expect(!MailServerConfig.isPinnedHost("example.com"))
        #expect(!MailServerConfig.isPinnedHost("notntust.edu.tw"))
        #expect(!MailServerConfig.isPinnedHost(""))
    }

    /// The scheme the app asks for and the one SwiftMail acts on. `.startTLS` has to map to
    /// SwiftMail's required form: a server that does not advertise STARTTLS then fails the
    /// connection instead of quietly continuing in the clear.
    @Test func schemesMapOntoSwiftMailsTransportSecurity() {
        // By name, not by case: this bundle does not import SwiftMail (same reason
        // `SchoolMailCharsetHook.decodeHeader` exists).
        #expect(MailTransportScheme.implicitTLS.swiftMailTransportSecurityName == "implicitTLS")
        #expect(MailTransportScheme.startTLS.swiftMailTransportSecurityName == "startTLS")
        #expect(MailTransportScheme.plaintext.swiftMailTransportSecurityName == "plainText")
    }

    // MARK: Requirement 4 — the domain rules follow the effective configuration

    /// With no override, the rule is character for character the one it has always been: the
    /// school's own domain and anything under it. This is what keeps the shared `warnings.json`
    /// fixture agreeing with Android.
    @Test func theSchoolConfigurationKeepsTheOriginalDomainRule() {
        let school = MailServerConfig.school
        #expect(MailWarnings.isSchoolDomain("ntust.edu.tw", config: school))
        #expect(MailWarnings.isSchoolDomain("mail.ntust.edu.tw", config: school))
        #expect(MailWarnings.isSchoolDomain("MAIL.NTUST.EDU.TW.", config: school))
        #expect(!MailWarnings.isSchoolDomain("gmail.com", config: school))
        #expect(!MailWarnings.isSchoolDomain("notntust.edu.tw", config: school))
        #expect(!MailWarnings.isSchoolDomain("", config: school))
        #expect(MailWarnings.schoolMailDomain == "mail.ntust.edu.tw")
    }

    /// The reason requirement 4 exists: left hard-coded, every message in a test account is
    /// badged External and the warning layer is nothing but noise.
    @Test func anOverriddenDomainIsWhatCountsAsInside() {
        let config = MailServerConfig.resolve(override: Self.settings(domain: "example.com"))
        #expect(MailWarnings.isSchoolDomain("example.com", config: config))
        #expect(MailWarnings.isSchoolDomain("mail.example.com", config: config))
        #expect(!MailWarnings.isSchoolDomain("ntust.edu.tw", config: config))
        #expect(!MailWarnings.isSchoolDomain("example.com.evil.test", config: config))
    }

    @Test func theExternalSenderBannerFollowsTheEffectiveDomain() {
        let config = MailServerConfig.resolve(override: Self.settings(domain: "example.com"))
        func warnings(from address: String, config: MailServerConfig) -> [MailWarning] {
            MailWarnings.evaluate(
                MailWarningInput(fromAddress: address, fromName: nil, subject: "hi", plainText: "hi",
                                 links: [], attachments: []),
                config: config
            )
        }
        // Inside the overridden domain: no banner. Against the school configuration the same
        // address is external, which is exactly the noise this fixes.
        #expect(warnings(from: "me@example.com", config: config).isEmpty)
        #expect(warnings(from: "me@example.com", config: .school) == [.externalSender(address: "me@example.com")])
        // A school address is now the outside one.
        #expect(warnings(from: "someone@mail.ntust.edu.tw", config: config)
            == [.externalSender(address: "someone@mail.ntust.edu.tw")])
    }

    /// The mistyped-recipient bounce rule measures near misses of the mailbox domain, so it has
    /// to measure near misses of the *overridden* one.
    @Test func theMistypedRecipientRuleFollowsTheEffectiveDomain() {
        let config = MailServerConfig.resolve(override: Self.settings(domain: "example.com"))
        #expect(MailWarnings.isMistypedSchoolMailDomain("exarnple.com", config: config))
        #expect(!MailWarnings.isMistypedSchoolMailDomain("example.com", config: config))
        #expect(!MailWarnings.isMistypedSchoolMailDomain("exarnple.com", config: .school))
        #expect(MailWarnings.isMistypedSchoolMailDomain("mail.ntust.edu.wt", config: .school))

        let bounce = MailWarningInput(
            fromAddress: "", fromName: "Mail Deliver System", subject: "Returned mail",
            plainText: "no such user typo@exarnple.com", links: [], attachments: [], returnPath: "<>"
        )
        #expect(MailWarnings.evaluate(bounce, config: config).contains(.mistypedRecipient))
        #expect(!MailWarnings.evaluate(bounce, config: .school).contains(.mistypedRecipient))
    }

    /// The password-bait gate counts a link as "outside" through the same domain rule, so a
    /// link to the test account's own webmail is not treated as an outside link.
    @Test func thePasswordBaitLinkGateFollowsTheEffectiveDomain() {
        let config = MailServerConfig.resolve(override: Self.settings(domain: "example.com"))
        let input = MailWarningInput(
            fromAddress: "me@example.com", fromName: nil, subject: "Please verify your account",
            plainText: "click", links: [MailLink(text: "here", href: "https://mail.example.com/login")],
            attachments: []
        )
        #expect(!MailWarnings.evaluate(input, config: config).contains(.passwordBait))
        #expect(MailWarnings.evaluate(input, config: .school).contains(.passwordBait))
    }

    // MARK: The address the app writes

    @Test func theAddressDomainReachesTheAddressAndTheMessageID() {
        // The effective configuration is the school one in this process, so these pin the real
        // path; the override's own effect on them is covered by the resolution tests above,
        // which is where the domain actually comes from.
        #expect(MailConstants.address(forStudentID: " b10000000 ") == "b10000000@mail.ntust.edu.tw")
        #expect(MailMessageBuilder.makeMessageID().hasSuffix("@mail.ntust.edu.tw>"))
    }

    /// A username that is already an address does not get a second domain appended. A student
    /// ID never contains `@`, so this changes nothing on the school path.
    @Test func aUsernameThatIsAlreadyAnAddressIsLeftAlone() {
        #expect(MailConstants.address(forStudentID: " Me@Example.com ") == "me@example.com")
        #expect(MailAccountManager.normalizedUsername(" b10000000 ") == "B10000000")
        #expect(MailAccountManager.normalizedUsername(" Me@Example.com ") == "Me@Example.com")
    }

    // MARK: Requirement 3 — a change resets the mail state

    /// `DevMailServerSettings` over its own defaults suite, never the app's.
    static func harness() -> (settings: DevMailServerSettings, resets: Box) {
        let suite = UserDefaults(suiteName: "dev-mail-server-\(UUID().uuidString)")!
        let box = Box()
        let settings = DevMailServerSettings(
            store: DevMailServerOverride(defaults: suite),
            resetMailState: { box.count += 1 }
        )
        return (settings, box)
    }

    final class Box {
        var count = 0
    }

    @Test func switchingTheOverrideOnAndOffEachResetTheMailState() {
        let h = Self.harness()
        #expect(h.settings.effectiveConfig == .school)

        h.settings.draft = Self.settings()
        #expect(h.settings.apply())
        #expect(h.resets.count == 1)
        #expect(h.settings.generation == 1)
        #expect(h.settings.effectiveConfig.imapHost == "imap.example.com")

        #expect(h.settings.resetToSchoolServer())
        #expect(h.resets.count == 2)
        #expect(h.settings.generation == 2)
        #expect(h.settings.effectiveConfig == .school)
    }

    /// Changing the server while signed in is the case the reset exists for.
    @Test func changingTheServerWhileTheOverrideIsAlreadyOnAlsoResets() {
        let h = Self.harness()
        h.settings.draft = Self.settings()
        h.settings.apply()
        h.settings.draft.imapHost = "imap.other.test"
        #expect(h.settings.apply())
        #expect(h.resets.count == 2)
        #expect(h.settings.effectiveConfig.imapHost == "imap.other.test")
    }

    /// A save that resolves to the same configuration is not a change, and must not sign
    /// anyone out: editing a field while the override is off, or correcting a typo back to what
    /// it was, would otherwise wipe the account every time.
    @Test func aSaveThatChangesNothingEffectiveResetsNothing() {
        let h = Self.harness()
        // Fields edited while the override is off.
        h.settings.draft = Self.settings(enabled: false, imapHost: "imap.other.test")
        #expect(!h.settings.apply())
        #expect(h.resets.count == 0)
        #expect(h.settings.generation == 0)

        h.settings.draft = Self.settings()
        h.settings.apply()
        // Re-applying the same thing, and applying a difference that normalizes away.
        #expect(!h.settings.apply())
        h.settings.draft.imapHost = "  IMAP.Example.com  "
        #expect(!h.settings.apply())
        #expect(h.resets.count == 1)
    }

    /// The draft survives a round trip through storage, so re-opening the screen shows what was
    /// applied rather than an empty form.
    @Test func theAppliedSettingsArePersisted() {
        let suite = UserDefaults(suiteName: "dev-mail-server-\(UUID().uuidString)")!
        let store = DevMailServerOverride(defaults: suite)
        store.save(Self.settings(domain: "example.com", imapPort: 1143))
        #expect(DevMailServerOverride(defaults: suite).settings.imapPort == 1143)
        #expect(DevMailServerOverride(defaults: suite).effectiveConfig.addressDomain == "example.com")
        store.clear()
        #expect(DevMailServerOverride(defaults: suite).effectiveConfig == .school)
    }

    // MARK: An override may not name a school host

    /// The premise `DevMailConnectionProbe.credentials(appliedIsOverridden:)` reasons from —
    /// "the applied configuration is an override, so the saved password is not the school's" —
    /// was not enforced anywhere. `resolve(override:)` only clamps a school host's TLS scheme;
    /// it never refuses one, so the override could be applied pointing at the school server.
    @Test func anOverrideNamingASchoolHostIsRefused() {
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings()) == nil)
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings(imapHost: "mail.ntust.edu.tw")) != nil)
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings(smtpHost: "MAIL.NTUST.EDU.TW")) != nil)
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings(imapHost: "imap.ntust.edu.tw")) != nil)
        // Switching the override off is how you go back to the school server, and must stay
        // possible — the refusal is about *naming* a school host under an enabled override.
        #expect(DevMailServerSettings.applyRefusal(for: MailServerOverrideSettings()) == nil)
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings(enabled: false, imapHost: "mail.ntust.edu.tw")) == nil)
    }

    /// The rule is the commit's, not the button's: a refused draft changes nothing and signs
    /// nobody out, however it was reached.
    @Test func applyingARefusedDraftCommitsNothing() {
        let h = Self.harness()
        h.settings.draft = Self.settings(imapHost: "mail.ntust.edu.tw")
        #expect(!h.settings.apply())
        #expect(h.settings.effectiveConfig == .school)
        #expect(!h.settings.effectiveConfig.isOverridden)
        #expect(h.resets.count == 0)

        h.settings.draft = Self.settings()
        #expect(h.settings.apply())
        #expect(h.settings.effectiveConfig.isOverridden)
        #expect(h.resets.count == 1)
    }

    /// The override's key is deliberately not one of the `school_mail_*` keys
    /// `DefaultsMailPreferences.reset()` clears — applying an override signs out, so an
    /// override stored under one of those would erase itself on the way in.
    @Test func signingOutDoesNotClearTheOverride() {
        let suite = UserDefaults(suiteName: "dev-mail-server-\(UUID().uuidString)")!
        let store = DevMailServerOverride(defaults: suite)
        store.save(Self.settings())
        DefaultsMailPreferences(defaults: suite).reset()
        #expect(DevMailServerOverride(defaults: suite).effectiveConfig.isOverridden)
    }
}
#endif
