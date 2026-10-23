#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailFolderProvisionerTests {
    nonisolated static let sent = MailFolderRole.sent.imapName
    nonisolated static let drafts = MailFolderRole.drafts.imapName
    nonisolated static let trash = MailFolderRole.trash.imapName
    nonisolated static let junk = MailFolderRole.junk.imapName

    @Test(arguments: [MailFolderRole.sent, .drafts, .trash])
    func aMissingRoleFolderIsCreatedAndResolvesBackToItsRole(role: MailFolderRole) async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let ensured = try #require(await MailFolderProvisioner.ensure(role, in: [.inbox: "INBOX"], client: fake))

        #expect(ensured.name == role.imapName)
        #expect(ensured.roles[role] == role.imapName)
        #expect(await fake.calls.contains("createFolder \(role.imapName)"))
        let available = try await fake.listFolders()
        #expect(available.contains(role.imapName))
        #expect(MailFolderMap.resolve(available: available)[role] == ensured.name)
    }

    @Test func theCreatedNameIsTheFormRoleResolutionMatchesBack() {
        for role in MailFolderProvisioner.creatableRoles {
            #expect(MailFolderMap.resolve(available: [role.imapName])[role] == role.imapName)
            #expect(ModifiedUTF7.decode(role.imapName) == role.decodedName)
            // Double-encoded: modified UTF-7 escapes a literal "&" as "&-", so an already-encoded
            // name run through an encoder once more comes back as a mailbox literally *named*
            // "&W8RO9lCZTv1TIw-" — decoding it yields that string, not the folder's real name.
            let doubleEncoded = "&-" + role.imapName.dropFirst()
            #expect(ModifiedUTF7.decode(doubleEncoded) == role.imapName)
            #expect(MailFolderMap.resolve(available: [doubleEncoded])[role] == nil)
        }
    }

    @Test(arguments: [MailFolderRole.junk, .inbox])
    func aRoleOutsideTheCreatableSetIsNeverCreated(role: MailFolderRole) async {
        let fake = FakeMailClient(folders: [:])
        #expect(await MailFolderProvisioner.ensure(role, in: [:], client: fake) == nil)
        #expect(await fake.calls.isEmpty)
        #expect(await fake.folders.isEmpty)
    }

    @Test(arguments: [MailFolderRole.sent, .drafts, .trash])
    func aMailboxHoldingOtherClientsFoldersStillGetsTheAppsOwnOne(role: MailFolderRole) async throws {
        let others = ["Sent", "Sent Items", "Sent Messages", "Drafts", "Trash"]
        let fake = FakeMailClient(folders: Dictionary(uniqueKeysWithValues:
            (["INBOX"] + others).map { ($0, [FakeMailClient.Message]()) }))
        let known = MailFolderMap.resolve(available: try await fake.listFolders())
        #expect(known == [.inbox: "INBOX"])

        let ensured = try #require(await MailFolderProvisioner.ensure(role, in: known, client: fake))
        #expect(ensured.name == role.imapName)
        #expect(ensured.roles[role] == role.imapName)
        #expect(await fake.calls.contains("createFolder \(role.imapName)"))
        #expect(await fake.folders.keys.sorted() == (["INBOX"] + others + [role.imapName]).sorted())
        for other in others { #expect(ensured.roles.values.contains(other) == false) }
    }

    @Test func aFolderThatAlreadyResolvesIsNeverTouched() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [], Self.sent: []])
        let ensured = try #require(await MailFolderProvisioner.ensure(.sent, in: [.sent: Self.sent], client: fake))
        #expect(ensured.name == Self.sent)
        #expect(await fake.calls.isEmpty)
    }

    /// Two operations can race each other to the same folder, or another client can have made it
    /// a moment ago. The server then refuses the `CREATE` — and Mail2000 has no response code to
    /// say why — so the only honest answer comes from asking what folders exist now.
    @Test func aCreateRefusedBecauseTheMailboxExistsCountsAsSuccess() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [], Self.trash: []])
        let ensured = try #require(await MailFolderProvisioner.ensure(.trash, in: [.inbox: "INBOX"], client: fake))
        #expect(ensured.name == Self.trash)
        #expect(ensured.roles[.trash] == Self.trash)
        #expect(await fake.calls.contains("createFolder \(Self.trash)"))
    }

    @Test func aRefusedCreateReportsFailureInsteadOfAFolderThatIsNotThere() async {
        let fake = FakeMailClient(folders: ["INBOX": []])
        await fake.update { $0.createFolderError = .protocolError("permission denied") }
        #expect(await MailFolderProvisioner.ensure(.drafts, in: [.inbox: "INBOX"], client: fake) == nil)
        #expect(await fake.folders["INBOX"] != nil)
        #expect(await fake.folders.count == 1)
    }

    @Test func aCreatedFolderThatDoesNotResolveBackIsReportedAsFailure() async {
        let fake = FakeMailClient(folders: ["INBOX": []])
        await fake.update { $0.createdFolderName = "&-" + Self.sent.dropFirst() }
        #expect(await MailFolderProvisioner.ensure(.sent, in: [.inbox: "INBOX"], client: fake) == nil)
    }

    @Test func aFolderListThatFailsAfterTheCreateReportsFailure() async {
        let fake = FakeMailClient(folders: ["INBOX": []])
        await fake.update { $0.listFoldersError = .serverBusy }
        #expect(await MailFolderProvisioner.ensure(.sent, in: [.inbox: "INBOX"], client: fake) == nil)
    }

    @Test func theDemoMailboxNeverCreatesAFolder() async throws {
        let fixture = MailDemoFixture(studentId: "B99999999", password: "tigerduck-review", uidValidity: 1,
                                      folders: ["INBOX": []])
        let demo = DemoMailClient(fixture: fixture)
        #expect(await MailFolderProvisioner.ensure(.sent, in: [.inbox: "INBOX"], client: demo) == nil)
        #expect(try await demo.listFolders() == ["INBOX"])
    }

    @Test func sendingWithNoSentFolderCreatesOneAndFilesTheCopy() async throws {
        let h = Self.compose(mode: .new, sentFolderExists: false)
        h.model.to = "a@mail.ntust.edu.tw"
        h.model.body = "hi"
        await h.model.send()

        #expect(h.model.didFinish)
        #expect(h.model.error == nil)
        #expect(await h.fake.sent.count == 1)
        #expect(await h.fake.folders[Self.sent]?.count == 1)
        #expect(h.reportedRoles.last?[.sent] == Self.sent)
    }

    @Test func aSentFolderThatCannotBeCreatedStillSendsTheMail() async {
        let h = Self.compose(mode: .new, sentFolderExists: false)
        await h.fake.update { $0.createFolderError = .protocolError("permission denied") }
        h.model.to = "a@mail.ntust.edu.tw"
        h.model.body = "hi"
        await h.model.send()

        #expect(h.model.didFinish)
        #expect(h.model.error == nil)
        #expect(await h.fake.sent.count == 1)
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("append ") })
        #expect(h.reportedRoles.isEmpty)
    }

    @Test func aFailedSendCreatesNothing() async {
        let h = Self.compose(mode: .new, sentFolderExists: false)
        await h.fake.update { $0.sendError = .serverBusy }
        h.model.to = "a@mail.ntust.edu.tw"
        h.model.body = "hi"
        await h.model.send()

        #expect(!h.model.didFinish)
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
    }

    @Test func sendingWithASentFolderCreatesNothing() async {
        let h = Self.compose(mode: .new, sentFolderExists: true)
        h.model.to = "a@mail.ntust.edu.tw"
        h.model.body = "hi"
        await h.model.send()

        #expect(h.model.didFinish)
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
        #expect(h.reportedRoles.isEmpty)
    }

    @Test func savingADraftWithNoDraftsFolderCreatesOne() async {
        let h = Self.compose(mode: .new, draftsFolderExists: false)
        h.model.to = "a@mail.ntust.edu.tw"
        h.model.body = "later"
        #expect(await h.model.saveDraft())

        #expect(h.model.error == nil)
        #expect(await h.fake.folders[Self.drafts]?.count == 1)
        #expect(h.reportedRoles.last?[.drafts] == Self.drafts)
    }

    @Test func aDraftsFolderThatCannotBeCreatedSurfacesTheError() async {
        let h = Self.compose(mode: .new, draftsFolderExists: false)
        await h.fake.update { $0.createFolderError = .protocolError("permission denied") }
        h.model.to = "a@mail.ntust.edu.tw"
        h.model.body = "later"
        #expect(await h.model.saveDraft() == false)

        #expect(h.model.error == String(localized: "school_mail_error_generic"))
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("append ") })
    }

    @Test func aDraftThatFailsValidationCreatesNothing() async {
        let h = Self.compose(mode: .new, draftsFolderExists: false)
        h.model.to = "abc"
        #expect(await h.model.saveDraft() == false)

        #expect(h.model.invalidRecipients == ["abc"])
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
    }

    @Test func savingADraftWithADraftsFolderCreatesNothing() async {
        let h = Self.compose(mode: .new, draftsFolderExists: true)
        h.model.body = "later"
        #expect(await h.model.saveDraft())
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
    }

    @Test func deletingWithNoTrashFolderCreatesOneAndMovesTheMail() async {
        let h = Self.message(trashFolderExists: false)
        await h.model.load()
        #expect(h.model.deleteIsPermanent)

        #expect(await h.model.prepareDelete() == false)
        #expect(!h.model.deleteIsPermanent)
        #expect(h.reportedRoles.last?[.trash] == Self.trash)
        #expect(!h.model.isMoving)

        #expect(await h.model.delete())
        #expect(await h.fake.folders[Self.trash]?.count == 1)
        #expect(await h.fake.folders["INBOX"]?.isEmpty == true)
    }

    @Test func aTrashFolderThatCannotBeCreatedKeepsDeleteBehindThePermanentConfirmation() async {
        let h = Self.message(trashFolderExists: false)
        await h.fake.update { $0.createFolderError = .protocolError("permission denied") }
        await h.model.load()

        #expect(await h.model.prepareDelete())
        #expect(h.model.deleteIsPermanent)
        #expect(h.reportedRoles.isEmpty)

        #expect(await h.model.delete())
        #expect(await h.fake.folders["INBOX"]?.isEmpty == true)
        #expect(await h.fake.folders[Self.trash] == nil)
    }

    @Test func preparingADeleteWithATrashFolderCreatesNothing() async {
        let h = Self.message(trashFolderExists: true)
        await h.model.load()
        #expect(await h.model.prepareDelete() == false)
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
        #expect(h.reportedRoles.isEmpty)
    }

    @Test func deletingInsideTrashStaysPermanentAndCreatesNothing() async {
        let h = Self.message(trashFolderExists: true, folder: Self.trash)
        await h.model.load()
        #expect(await h.model.prepareDelete())
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
    }

    @Test func readingMailNeverCreatesAFolder() async {
        let h = Self.message(trashFolderExists: false)
        await h.model.load()
        await h.model.toggleSeen()
        await h.model.loadSource()
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
    }

    @Test func resolvingTheFolderListNeverCreatesAFolder() async {
        let h = MailListViewModelTests.harness(inboxCount: 3, includeSent: false)
        await h.model.load()
        #expect(h.model.folderRoles[.sent] == nil)
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
    }

    @Test func theListAdoptsARoleMapAScreenReResolved() async {
        let h = MailListViewModelTests.harness(inboxCount: 3, includeSent: false)
        await h.model.load()
        var roles = h.model.folderRoles
        roles[.sent] = Self.sent
        h.model.adoptFolderRoles(roles)
        #expect(h.model.folderRoles[.sent] == Self.sent)
    }

    struct ComposeHarness {
        let model: MailComposeViewModel
        let fake: FakeMailClient
        let reportedRoles: Reported
    }

    struct MessageHarness {
        let model: MailMessageViewModel
        let fake: FakeMailClient
        let reportedRoles: Reported
    }

    @MainActor
    final class Reported {
        private(set) var maps: [[MailFolderRole: String]] = []
        var isEmpty: Bool { maps.isEmpty }
        var last: [MailFolderRole: String]? { maps.last }
        func record(_ roles: [MailFolderRole: String]) { maps.append(roles) }
    }

    static func compose(mode: MailComposeMode, sentFolderExists: Bool = true,
                        draftsFolderExists: Bool = true) -> ComposeHarness {
        var folders: [String: [FakeMailClient.Message]] = ["INBOX": []]
        var roles: [MailFolderRole: String] = [.inbox: "INBOX"]
        if sentFolderExists {
            folders[Self.sent] = []
            roles[.sent] = Self.sent
        }
        if draftsFolderExists {
            folders[Self.drafts] = []
            roles[.drafts] = Self.drafts
        }
        let fake = FakeMailClient(folders: folders)
        let prefs = InMemoryMailPreferences()
        let model = MailComposeViewModel(
            context: MailComposeContext(mode: mode),
            session: MailPageSession(idleClose: .milliseconds(10), open: { fake },
                                     onAuthFailure: { prefs.authFailed = true }),
            sender: MailComposeViewModelTests.me,
            folderRoles: roles,
            prefs: prefs,
            cache: SchoolMailTestDoubles.temporaryCache(),
            sleep: { _ in }
        )
        let reported = Reported()
        model.onFolderRolesChanged = { reported.record($0) }
        return ComposeHarness(model: model, fake: fake, reportedRoles: reported)
    }

    static func message(trashFolderExists: Bool, folder: String = "INBOX") -> MessageHarness {
        let message = FakeMailClient.message(uid: 5)
        var folders: [String: [FakeMailClient.Message]] = [folder: [message]]
        var roles: [MailFolderRole: String] = [.inbox: "INBOX"]
        if trashFolderExists {
            folders[Self.trash] = folders[Self.trash] ?? []
            roles[.trash] = Self.trash
        }
        let fake = FakeMailClient(folders: folders)
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: folder, uidValidity: 1, messageCount: 1,
                                      summaries: [message.summary], oldestLoadedSequence: nil))
        let prefs = InMemoryMailPreferences()
        prefs.inboxUIDValidity = 1
        let model = MailMessageViewModel(
            route: MailMessageRoute(folder: folder, uid: 5),
            session: MailPageSession(idleClose: .milliseconds(10), open: { fake }),
            folderRoles: roles,
            cache: cache, prefs: prefs, notifier: MailNotifier(center: RecordingNotificationCenter())
        )
        let reported = Reported()
        model.onFolderRolesChanged = { reported.record($0) }
        return MessageHarness(model: model, fake: fake, reportedRoles: reported)
    }
}
#endif
