#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// Sent, Drafts and Trash are not guaranteed to exist on a Mail2000 account, and the user can
/// delete any of them at any time. These cover what the app does about that: it creates one at
/// the moment an operation needs it, never before, never `.junk` or `INBOX`, and never in a way
/// that lets a failed `CREATE` cost the user their action — least of all turn Delete into a
/// silent, unconfirmed hard delete.
@MainActor
struct MailFolderProvisionerTests {
    nonisolated static let sent = MailFolderRole.sent.imapName
    nonisolated static let drafts = MailFolderRole.drafts.imapName
    nonisolated static let trash = MailFolderRole.trash.imapName
    nonisolated static let junk = MailFolderRole.junk.imapName

    // MARK: The provisioner itself

    /// The whole round trip, not "createFolder was called with X": the name goes to the server,
    /// comes back from a fresh `LIST`, and `MailFolderMap` — the ordinary resolution path,
    /// untouched by any of this — has to map it to the same role again. A name created in the
    /// wrong form would come back as a mailbox nothing recognises, and the next operation would
    /// create yet another one.
    @Test(arguments: [MailFolderRole.sent, .drafts, .trash])
    func aMissingRoleFolderIsCreatedAndResolvesBackToItsRole(role: MailFolderRole) async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let ensured = try #require(await MailFolderProvisioner.ensure(role, in: [.inbox: "INBOX"], client: fake))

        #expect(ensured.name == role.imapName)
        #expect(ensured.roles[role] == role.imapName)
        #expect(await fake.calls.contains("createFolder \(role.imapName)"))
        // The server now has it, and resolving the server's own answer finds the role again.
        let available = try await fake.listFolders()
        #expect(available.contains(role.imapName))
        #expect(MailFolderMap.resolve(available: available)[role] == ensured.name)
    }

    /// Which form of the name goes on the wire. Mail2000's folder names are modified UTF-7, which
    /// is what `imapName` holds and what `listFolders()` reports; nothing between the provisioner
    /// and the socket re-encodes it. Sending the decoded display name, or an already-encoded name
    /// through a layer that encodes again, both produce a mailbox that resolution can never match
    /// — the failure that looks like success.
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

    /// The server's spam classifier owns Junk; the app never writes to it, so a folder the server
    /// does not know about achieves nothing there and may confuse filtering. `INBOX` is
    /// guaranteed by RFC 3501 and is never created either.
    @Test(arguments: [MailFolderRole.junk, .inbox])
    func aRoleOutsideTheCreatableSetIsNeverCreated(role: MailFolderRole) async {
        let fake = FakeMailClient(folders: [:])
        #expect(await MailFolderProvisioner.ensure(role, in: [:], client: fake) == nil)
        #expect(await fake.calls.isEmpty)
        #expect(await fake.folders.isEmpty)
    }

    /// Creation is not the school server's privilege: a mailbox on any other server — the one a
    /// developer reaches through the Email override — gets the same three folders.
    ///
    /// This is the case the decision was made for. The account already has `Sent`, `Sent Items`
    /// and `Sent Messages` left behind by other clients; resolution matches by name and never by
    /// a SPECIAL-USE attribute, so none of them is a role and there is no honest way to pick one
    /// of the three to file into. One unambiguous app-owned set, spelled the same everywhere,
    /// beats that guess — so the app creates its own and leaves theirs alone.
    @Test(arguments: [MailFolderRole.sent, .drafts, .trash])
    func aMailboxHoldingOtherClientsFoldersStillGetsTheAppsOwnOne(role: MailFolderRole) async throws {
        let others = ["Sent", "Sent Items", "Sent Messages", "Drafts", "Trash"]
        let fake = FakeMailClient(folders: Dictionary(uniqueKeysWithValues:
            (["INBOX"] + others).map { ($0, [FakeMailClient.Message]()) }))
        // None of the account's own folders is a role, so the role map is just the inbox.
        let known = MailFolderMap.resolve(available: try await fake.listFolders())
        #expect(known == [.inbox: "INBOX"])

        let ensured = try #require(await MailFolderProvisioner.ensure(role, in: known, client: fake))
        #expect(ensured.name == role.imapName)
        #expect(ensured.roles[role] == role.imapName)
        #expect(await fake.calls.contains("createFolder \(role.imapName)"))
        // Theirs are still there, still unresolved, and still not written to.
        #expect(await fake.folders.keys.sorted() == (["INBOX"] + others + [role.imapName]).sorted())
        for other in others { #expect(ensured.roles.values.contains(other) == false) }
    }

    /// A folder that is already resolved costs nothing at all — no `CREATE`, and no `LIST` either.
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
        // The caller's map is stale: the folder is on the server already.
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

    /// A `CREATE` the server accepted but filed under a name of its own making. Mail2000 mangles
    /// other responses (vendored patches 5 and 6), so this is plausible rather than paranoid — and
    /// the answer must be "failed", not a folder name role resolution will never match again.
    @Test func aCreatedFolderThatDoesNotResolveBackIsReportedAsFailure() async {
        let fake = FakeMailClient(folders: ["INBOX": []])
        await fake.update { $0.createdFolderName = "&-" + Self.sent.dropFirst() }
        #expect(await MailFolderProvisioner.ensure(.sent, in: [.inbox: "INBOX"], client: fake) == nil)
    }

    /// The `LIST` is what decides, so a `LIST` that fails decides nothing: the caller falls back
    /// rather than assuming its own `CREATE` worked.
    @Test func aFolderListThatFailsAfterTheCreateReportsFailure() async {
        let fake = FakeMailClient(folders: ["INBOX": []])
        await fake.update { $0.listFoldersError = .serverBusy }
        #expect(await MailFolderProvisioner.ensure(.sent, in: [.inbox: "INBOX"], client: fake) == nil)
    }

    /// The demo mailbox is entirely local and its fixture already carries every role folder, so
    /// nothing may ever be created there. The client refuses rather than relying on callers to
    /// remember, and a refusal is just the ordinary fallback.
    @Test func theDemoMailboxNeverCreatesAFolder() async throws {
        let fixture = MailDemoFixture(studentId: "B99999999", password: "tigerduck-review", uidValidity: 1,
                                      folders: ["INBOX": []])
        let demo = DemoMailClient(fixture: fixture)
        #expect(await MailFolderProvisioner.ensure(.sent, in: [.inbox: "INBOX"], client: demo) == nil)
        #expect(try await demo.listFolders() == ["INBOX"])
    }

    // MARK: Sent — filing the copy of a mail that has gone out

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

    /// Sending is the point; filing the copy is not worth failing it for. This is exactly what an
    /// account with no Sent folder did before — the mail goes, no copy is kept — and it must stay
    /// that way when the folder cannot be made.
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

    /// The copy only exists once the mail has gone out, so a send that failed must leave no folder
    /// behind — nothing was ever going to be filed in it.
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

    // MARK: Drafts — keeping a draft the user asked to save

    @Test func savingADraftWithNoDraftsFolderCreatesOne() async {
        let h = Self.compose(mode: .new, draftsFolderExists: false)
        h.model.to = "a@mail.ntust.edu.tw"
        h.model.body = "later"
        #expect(await h.model.saveDraft())

        #expect(h.model.error == nil)
        #expect(await h.fake.folders[Self.drafts]?.count == 1)
        #expect(h.reportedRoles.last?[.drafts] == Self.drafts)
    }

    /// Unlike a sent copy, a draft that is not kept is the user's own work lost — so this is the
    /// one of the three that must surface an error rather than carry on quietly.
    @Test func aDraftsFolderThatCannotBeCreatedSurfacesTheError() async {
        let h = Self.compose(mode: .new, draftsFolderExists: false)
        await h.fake.update { $0.createFolderError = .protocolError("permission denied") }
        h.model.to = "a@mail.ntust.edu.tw"
        h.model.body = "later"
        #expect(await h.model.saveDraft() == false)

        #expect(h.model.error == String(localized: "school_mail_error_generic"))
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("append ") })
    }

    /// A save that was never going to happen must not leave a folder behind: the validation the
    /// draft would have failed anyway runs first.
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

    // MARK: Trash — the one where a failure must never destroy mail

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
        // Moved, not destroyed: the copy is in Trash and the original is gone from the inbox.
        #expect(await h.fake.folders["INBOX"]?.isEmpty == true)
    }

    /// The critical one. A Trash folder that cannot be created must leave Delete exactly where it
    /// was: permanent, and therefore behind the permanent-delete confirmation — never a delete
    /// that destroys mail with no dialog, and never one that silently does nothing.
    @Test func aTrashFolderThatCannotBeCreatedKeepsDeleteBehindThePermanentConfirmation() async {
        let h = Self.message(trashFolderExists: false)
        await h.fake.update { $0.createFolderError = .protocolError("permission denied") }
        await h.model.load()

        // `prepareDelete()` is what the Delete button runs before either dialog; `true` is the
        // answer that raises the permanent-delete confirmation.
        #expect(await h.model.prepareDelete())
        #expect(h.model.deleteIsPermanent)
        #expect(h.reportedRoles.isEmpty)

        // ...and only from behind that dialog does the delete itself run.
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

    /// Deleting *inside* Trash is permanent by definition, and there is nothing to create.
    @Test func deletingInsideTrashStaysPermanentAndCreatesNothing() async {
        let h = Self.message(trashFolderExists: true, folder: Self.trash)
        await h.model.load()
        #expect(await h.model.prepareDelete())
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
    }

    // MARK: Nothing speculative

    /// Reading mail — opening the screen, marking it read, reading its source — never creates
    /// anything, on an account that has none of the three.
    @Test func readingMailNeverCreatesAFolder() async {
        let h = Self.message(trashFolderExists: false)
        await h.model.load()
        await h.model.toggleSeen()
        await h.model.loadSource()
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
    }

    /// Resolving the folder list is the other place a folder could plausibly have been conjured
    /// up — a list that knows Sent is missing must simply carry on without it.
    @Test func resolvingTheFolderListNeverCreatesAFolder() async {
        let h = MailListViewModelTests.harness(inboxCount: 3, includeSent: false)
        await h.model.load()
        #expect(h.model.folderRoles[.sent] == nil)
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("createFolder") })
    }

    /// The list adopts a map a screen re-resolved after creating a folder, so the chip appears and
    /// the next screen it opens does not try to create the same folder all over again.
    @Test func theListAdoptsARoleMapAScreenReResolved() async {
        let h = MailListViewModelTests.harness(inboxCount: 3, includeSent: false)
        await h.model.load()
        var roles = h.model.folderRoles
        roles[.sent] = Self.sent
        h.model.adoptFolderRoles(roles)
        #expect(h.model.folderRoles[.sent] == Self.sent)
    }

    // MARK: Harnesses

    struct ComposeHarness {
        let model: MailComposeViewModel
        let fake: FakeMailClient
        /// Every role map the view model reported after creating a folder — empty when it never
        /// created one, which is most of these tests.
        let reportedRoles: Reported
    }

    struct MessageHarness {
        let model: MailMessageViewModel
        let fake: FakeMailClient
        let reportedRoles: Reported
    }

    /// A reference box for the callback's results, so a `let` harness can still collect them.
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
