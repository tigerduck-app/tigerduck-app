#if os(iOS)
import Foundation

@MainActor
enum MailMessageActions {
    static func move(model: MailMessageViewModel, to target: String) async -> Bool {
        let route = model.route
        return await performMove(model: model) { client, owned in
            try await MailMover.move(uids: [route.uid], from: route.folder, to: target, client: client, previouslyFlagged: owned)
        }
    }

    static func prepareDelete(model: MailMessageViewModel) async -> Bool {
        guard model.folderRoles[.trash] == nil, !model.isMoving else { return model.deleteIsPermanent }
        model.activity.isMoving = true
        defer { model.activity.isMoving = false }
        let known = model.folderRoles
        let ensured = try? await model.session.use { client in
            await MailFolderProvisioner.ensure(.trash, in: known, client: client)
        }
        if let ensured = ensured ?? nil { model.adoptFolderRoles(ensured.roles) }
        return model.deleteIsPermanent
    }

    static func delete(model: MailMessageViewModel) async -> Bool {
        if !model.deleteIsPermanent, let trash = model.folderRoles[.trash] {
            return await move(model: model, to: trash)
        }
        let route = model.route
        return await performMove(model: model) { client, owned in
            try await MailMover.deletePermanently(uids: [route.uid], in: route.folder, client: client, previouslyFlagged: owned)
        }
    }

    private static func performMove(
        model: MailMessageViewModel, _ operation: @escaping (any MailClient, OwnedDeleted) async throws -> MailMoveResult
    ) async -> Bool {
        guard !model.isMoving else { return false }
        let folder = model.route.folder
        guard let uidValidity = model.pageUIDValidity else {
            model.activity.actionError = MailAccountManager.LoginError(MailClientError.folderChanged).message
            return false
        }
        model.activity.isMoving = true
        defer { model.activity.isMoving = false }
        let signIn = await model.session.account.startingSignIn
        let uid = model.route.uid
        let prefs = model.stores.prefs
        let wasAlreadyDeleted = model.detail?.summary.isDeleted ?? false
        let owned = prefs.ownedDeleted(folder: folder, uidValidity: uidValidity)
        let attempt = await MailMover.attempt(
            { try await model.session.use { client in try await operation(client, owned) } },
            uid: uid, previouslyFlagged: owned, wasAlreadyDeleted: wasAlreadyDeleted
        ) { recover in
            (try? await model.session.use { client in await recover(client) }) ?? nil
        }
        if let pending = attempt.pending { prefs.change(for: signIn) { $0.setOwnedDeleted(pending) } }
        guard let error = attempt.error else {
            model.events.post(.removed(folder: folder, uid: uid))
            return true
        }
        model.activity.actionError = MailAccountManager.LoginError(error).message
        if (error as? MailClientError) == .folderChanged { model.events.post(.folderChanged(folder)) }
        return false
    }

    static func loadSource(model: MailMessageViewModel) async {
        model.activity.sourceLoadFailed = false
        let signIn = await model.session.account.startingSignIn
        let cache = model.stores.cache
        let folder = model.route.folder
        let uid = model.route.uid
        let validity = model.pageUIDValidity
        let wipeCount = cache.wipeCount
        if let validity,
           let cached = await Task.detached(operation: { cache.loadSource(folder: folder, uidValidity: validity, uid: uid) }).value {
            model.activity.source = cached
            return
        }
        do {
            let data = try await model.session.use { client in
                try await client.rawSource(folder: folder, uid: uid, expectedUIDValidity: validity)
            }
            let text = await Task.detached { String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }.value
            model.activity.source = text
            if let validity, signIn.isCurrent {
                await Task.detached { cache.saveSource(text, folder: folder, uidValidity: validity, uid: uid, unlessWipedSince: wipeCount) }.value
            }
        } catch {
            model.activity.actionError = MailAccountManager.LoginError(error).message
            model.activity.sourceLoadFailed = true
        }
    }

    static func prepareAttachment(_ part: MailBodyPart, model: MailMessageViewModel) async -> URL? {
        guard !model.downloading.contains(part.section) else { return nil }
        model.activity.downloading.insert(part.section)
        defer { model.activity.downloading.remove(part.section) }
        let folder = model.route.folder
        let uid = model.route.uid
        let validity = model.pageUIDValidity
        let cache = model.stores.cache
        let wipeCount = cache.wipeCount
        do {
            let data = try await model.session.use { client in
                try await client.attachment(folder: folder, uid: uid, part: part, expectedUIDValidity: validity)
            }
            let filename = MailAttachmentRisk.displayFilename(part.filename ?? "attachment")
            return try await Task.detached {
                try cache.saveAttachment(data, filename: filename, unlessWipedSince: wipeCount)
            }.value
        } catch {
            model.activity.actionError = MailAccountManager.LoginError(error).message
            return nil
        }
    }
}
#endif
