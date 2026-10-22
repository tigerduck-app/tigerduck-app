#if DEBUG && os(iOS)
import Foundation
import Testing
@testable import TigerDuck

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

    @Test func noOverrideIsInForceAndTheEffectiveConfigurationIsTheSchoolOne() {
        #expect(MailServerConfig.effective == .school)
        #expect(!MailServerConfig.effective.isOverridden)
    }

    @Test func anOverrideThatIsOffResolvesToTheSchoolServer() {
        #expect(MailServerConfig.resolve(override: MailServerOverrideSettings()) == .school)
        #expect(MailServerConfig.resolve(override: Self.settings(enabled: false)) == .school)
    }

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

    @Test func plaintextIsAllowedForAHostThatIsNotTheSchools() {
        let resolved = MailServerConfig.resolve(
            override: Self.settings(imapHost: "127.0.0.1", imapPort: 1143, imapScheme: .plaintext,
                                    smtpHost: "127.0.0.1", smtpPort: 1025, smtpScheme: .plaintext)
        )
        #expect(resolved.imapScheme == .plaintext)
        #expect(resolved.smtpScheme == .plaintext)
    }

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

    @Test func onlyTheSchoolSideOfAMixedConfigurationIsClamped() {
        let resolved = MailServerConfig.resolve(
            override: Self.settings(imapHost: "mail.ntust.edu.tw", imapPort: 143, imapScheme: .plaintext,
                                    smtpHost: "smtp.example.com", smtpPort: 587, smtpScheme: .startTLS)
        )
        #expect(resolved.imapScheme == .implicitTLS)
        #expect(resolved.smtpScheme == .startTLS)
    }

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
        #expect(MailTransportScheme.implicitTLS.swiftMailTransportSecurityName == "implicitTLS")
        #expect(MailTransportScheme.startTLS.swiftMailTransportSecurityName == "startTLS")
        #expect(MailTransportScheme.plaintext.swiftMailTransportSecurityName == "plainText")
    }

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
        #expect(warnings(from: "me@example.com", config: config).isEmpty)
        #expect(warnings(from: "me@example.com", config: .school) == [.externalSender(address: "me@example.com")])
        #expect(warnings(from: "someone@mail.ntust.edu.tw", config: config)
            == [.externalSender(address: "someone@mail.ntust.edu.tw")])
    }

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

    @Test func theAddressDomainReachesTheAddressAndTheMessageID() {
        #expect(MailConstants.address(forStudentID: " b10000000 ") == "b10000000@mail.ntust.edu.tw")
        #expect(MailMessageBuilder.makeMessageID().hasSuffix("@mail.ntust.edu.tw>"))
    }

    @Test func aUsernameThatIsAlreadyAnAddressIsLeftAlone() {
        #expect(MailConstants.address(forStudentID: " Me@Example.com ") == "me@example.com")
        #expect(MailAccountManager.normalizedUsername(" b10000000 ") == "B10000000")
        #expect(MailAccountManager.normalizedUsername(" Me@Example.com ") == "Me@Example.com")
    }

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

    @Test func changingTheServerWhileTheOverrideIsAlreadyOnAlsoResets() {
        let h = Self.harness()
        h.settings.draft = Self.settings()
        h.settings.apply()
        h.settings.draft.imapHost = "imap.other.test"
        #expect(h.settings.apply())
        #expect(h.resets.count == 2)
        #expect(h.settings.effectiveConfig.imapHost == "imap.other.test")
    }

    @Test func aSaveThatChangesNothingEffectiveResetsNothing() {
        let h = Self.harness()
        h.settings.draft = Self.settings(enabled: false, imapHost: "imap.other.test")
        #expect(!h.settings.apply())
        #expect(h.resets.count == 0)
        #expect(h.settings.generation == 0)

        h.settings.draft = Self.settings()
        h.settings.apply()
        #expect(!h.settings.apply())
        h.settings.draft.imapHost = "  IMAP.Example.com  "
        #expect(!h.settings.apply())
        #expect(h.resets.count == 1)
    }

    @Test func theAppliedSettingsArePersisted() {
        let suite = UserDefaults(suiteName: "dev-mail-server-\(UUID().uuidString)")!
        let store = DevMailServerOverride(defaults: suite)
        store.save(Self.settings(domain: "example.com", imapPort: 1143))
        #expect(DevMailServerOverride(defaults: suite).settings.imapPort == 1143)
        #expect(DevMailServerOverride(defaults: suite).effectiveConfig.addressDomain == "example.com")
        store.clear()
        #expect(DevMailServerOverride(defaults: suite).effectiveConfig == .school)
    }

    @Test func anOverrideNamingASchoolHostIsRefused() {
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings()) == nil)
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings(imapHost: "mail.ntust.edu.tw")) != nil)
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings(smtpHost: "MAIL.NTUST.EDU.TW")) != nil)
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings(imapHost: "imap.ntust.edu.tw")) != nil)
        #expect(DevMailServerSettings.applyRefusal(for: MailServerOverrideSettings()) == nil)
        #expect(DevMailServerSettings.applyRefusal(for: Self.settings(enabled: false, imapHost: "mail.ntust.edu.tw")) == nil)
    }

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

    @Test func signingOutDoesNotClearTheOverride() {
        let suite = UserDefaults(suiteName: "dev-mail-server-\(UUID().uuidString)")!
        let store = DevMailServerOverride(defaults: suite)
        store.save(Self.settings())
        DefaultsMailPreferences(defaults: suite).reset()
        #expect(DevMailServerOverride(defaults: suite).effectiveConfig.isOverridden)
    }
}
#endif
