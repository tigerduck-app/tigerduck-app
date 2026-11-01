import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class MoodleMemberPictures {

    private enum PictureRequest { case inFlight, done }

    private(set) var pictures: [URL: CGImage] = [:]
    @ObservationIgnored private var requests: [URL: PictureRequest] = [:]
    @ObservationIgnored private var lastPictureDownload: Task<Data?, Never>?
    @ObservationIgnored private var lastPictureRead: Task<CGImage?, Never>?
    @ObservationIgnored var readPictureFile: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    @ObservationIgnored var decodePicture: @Sendable (Data) -> CGImage? = { MoodleMemberPictures.image(from: $0) }
    @ObservationIgnored private let api: MoodleCourseAPI
    @ObservationIgnored private let context: MoodleCacheContext

    init(api: MoodleCourseAPI, context: MoodleCacheContext) {
        self.api = api
        self.context = context
    }

    func loadPicture(of member: MoodleMember) async {
        guard let url = member.pictureURL else { return }
        if requests[url] == .inFlight { _ = await lastPictureDownload?.value }
        guard requests[url] == nil else { return }
        let file = AccountPictureFolder.file(of: member, url: url, account: context.account, in: context.cache)
        let revision = Int(AccountPictureFolder.revision(of: url)) ?? 0
        if pictures[url] == nil, let kept = await readInTurn(file) {
            guard context.signIn.isCurrent else { return }
            pictures[url] = kept
        }
        guard let data = await downloadInTurn(url) else { return }
        let read = readPictureFile
        let decode = decodePicture
        let isShown = pictures[url] != nil
        let changed = await Task.detached(priority: .userInitiated) { () -> (CGImage, URL?)? in
            let folderHoldsIt = read(file) == data
            guard !folderHoldsIt || !isShown, let image = decode(data) else { return nil }
            guard !folderHoldsIt else { return (image, nil) }
            return AccountPictureFolder.stage(data, for: file, revision: revision).map { (image, $0) }
        }.value
        guard case let (image, staged)? = changed else { return }
        if let staged {
            guard AccountPictureFolder.place(staged, at: file, revision: revision, for: context.signIn) else { return }
        } else {
            guard context.signIn.isCurrent else { return }
        }
        pictures[url] = image
    }

    /// The member's own picture as a file named for them, which Quick Look opens and its share
    /// menu saves: Moodle's 512 px size of this revision, downloaded on the first open and kept,
    /// else the 100 px one the list shows; nil while neither is on the device. Quick Look tells an
    /// image by its extension, which the kept files have none of.
    func picturePreview(of member: MoodleMember) async -> URL? {
        guard let url = member.pictureURL, context.signIn.isCurrent else { return nil }
        let kept = AccountPictureFolder.file(of: member, url: url, account: context.account, in: context.cache)
        let large = kept.deletingLastPathComponent()
            .appendingPathComponent("\(kept.lastPathComponent)-\(AccountPictureFolder.revision(of: url))-f3")
        guard let data = await largePicture(of: url, keptAt: large) ?? (try? Data(contentsOf: kept)),
              context.signIn.isCurrent, let fileExtension = Self.fileExtension(of: data) else { return nil }
        let preview = kept.deletingLastPathComponent()
            .appendingPathComponent(kept.lastPathComponent + "-preview", isDirectory: true)
            .appendingPathComponent(MoodleFileDownloads.safeName(member.name))
            .appendingPathExtension(fileExtension)
        do {
            try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: preview, options: [.atomic, .completeFileProtectionUnlessOpen])
            return preview
        } catch {
            AppLogger.breadcrumb("moodle member picture preview not written: \(error)", category: "moodle")
            return nil
        }
    }

    private func largePicture(of url: URL, keptAt file: URL) async -> Data? {
        if let kept = try? Data(contentsOf: file) { return kept }
        guard let large = MoodleCourseMembersService.largePicture(url) else { return nil }
        do {
            let data = try await api.picture(large)
            guard Self.fileExtension(of: data) != nil, context.signIn.isCurrent else { return nil }
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            return data
        } catch {
            AppLogger.breadcrumb("moodle member large picture not downloaded: \(error)", category: "moodle")
            return nil
        }
    }

    private nonisolated static func fileExtension(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else { return nil }
        return type.preferredFilenameExtension
    }

    private func readInTurn(_ file: URL) async -> CGImage? {
        let previous = lastPictureRead
        let read = readPictureFile
        let decode = decodePicture
        let turn = Task.detached(priority: .userInitiated) { () -> CGImage? in
            _ = await previous?.value
            return read(file).flatMap(decode)
        }
        lastPictureRead = turn
        return await turn.value
    }

    private func downloadInTurn(_ url: URL) async -> Data? {
        let previous = lastPictureDownload
        let turn = Task { [api] () -> Data? in
            _ = await previous?.value
            guard !Task.isCancelled, self.requests[url] == nil else { return nil }
            self.requests[url] = .inFlight
            do {
                let data = try await api.picture(url)
                self.requests[url] = .done
                return data
            } catch {
                if Task.isCancelled {
                    self.requests[url] = nil
                } else {
                    self.requests[url] = .done
                    AppLogger.breadcrumb("moodle member picture not downloaded: \(error)", category: "moodle")
                }
                return nil
            }
        }
        lastPictureDownload = turn
        return await withTaskCancellationHandler { await turn.value } onCancel: { turn.cancel() }
    }

    private nonisolated static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

@MainActor
private enum AccountPictureFolder {
    private static var placedRevisions = SignInBound<[URL: Int]>(empty: [:])

    static func file(of member: MoodleMember, url: URL, account: String, in cache: MoodleFiles) -> URL {
        let account = folderName(account)
        let studentId = folderName(member.studentId ?? "")
        let name = studentId.isEmpty ? "\(member.id)-\(revision(of: url))" : studentId
        return cache.moodleFilesDir
            .appendingPathComponent(account.isEmpty ? "_" : account, isDirectory: true)
            .appendingPathComponent("pictures", isDirectory: true)
            .appendingPathComponent(name)
    }

    nonisolated static func revision(of url: URL) -> String {
        folderName(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "rev" }?.value ?? "")
    }

    private nonisolated static func folderName(_ text: String) -> String {
        String(text.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    nonisolated static func stage(_ data: Data, for file: URL, revision: Int) -> URL? {
        let files = FileManager.default
        let prefix = String(file.lastPathComponent.prefix { $0 != "-" }) + "-"
        let earlier = (try? files.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for old in earlier where old.lastPathComponent.hasPrefix(prefix) && old.lastPathComponent != file.lastPathComponent
            && (try? old.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            let oldRevision = Int(old.lastPathComponent.dropFirst(prefix.count).prefix { $0 != "-" })
            if (oldRevision ?? 0) <= revision { try? files.removeItem(at: old) }
        }
        let staged = files.temporaryDirectory.appendingPathComponent("MoodlePicture-\(UUID().uuidString)")
        do {
            try data.write(to: staged, options: [.atomic, .completeFileProtectionUnlessOpen])
            return staged
        } catch {
            return nil
        }
    }

    static func place(_ staged: URL, at file: URL, revision: Int, for signIn: SignIn) -> Bool {
        let files = FileManager.default
        guard signIn.isCurrent, isNewestRevision(revision, for: file) else {
            try? files.removeItem(at: staged)
            return false
        }
        var placed = placedRevisions.value
        placed[file] = revision
        placedRevisions.set(placed, for: signIn)
        try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: file)
        if (try? files.moveItem(at: staged, to: file)) == nil { try? files.removeItem(at: staged) }
        return true
    }

    private static func isNewestRevision(_ revision: Int, for file: URL) -> Bool {
        revision >= placedRevisions.value[file, default: 0]
    }
}
