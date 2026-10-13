import QuickLook
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A file a Moodle screen lists, with what it belongs to.
nonisolated struct MoodleFileRef: Hashable, Sendable {
    let file: MoodleFile
    let owner: MoodleFileOwner
}

extension MoodleMaterial {
    /// The files it holds, which belong to its module.
    var fileRefs: [MoodleFileRef] {
        switch content {
        case .file(let file): [MoodleFileRef(file: file, owner: .module(id))]
        case .folder(let files): files.map { MoodleFileRef(file: $0, owner: .module(id)) }
        case .link: []
        }
    }
}

extension MoodleCourseMaterials {
    var fileRefs: [MoodleFileRef] {
        sections.flatMap { $0.materials.flatMap(\.fileRefs) }
    }
}

/// What a screen of Moodle files does with them. A tap downloads a file, stops its download, or
/// opens it in Quick Look with the screen's other downloaded files to swipe through. A file that
/// finishes downloading opens only while the screen shows and it is the last file tapped, so
/// several taps in a row do not open one preview after another.
@Observable
@MainActor
final class MoodleFileOpener {
    var preview: URL?
    private(set) var previewItems: [URL] = []
    var shared: MoodleSharedItem?
    @ObservationIgnored var isOnScreen = false
    @ObservationIgnored private var lastTapped: URL?

    /// `opened` runs each time the file opens, for its view on Moodle.
    func tap(
        _ ref: MoodleFileRef,
        among neighbours: [MoodleFileRef],
        store: MoodleCourseStore,
        opened: @escaping () -> Void = {}
    ) {
        let location = store.location(of: ref.file, in: ref.owner)
        lastTapped = location
        switch store.downloadState(of: ref.file, in: ref.owner) {
        case .downloading:
            store.cancelDownload(of: ref.file, in: ref.owner)
        case .downloaded(let copy):
            show(copy, of: ref.file, among: neighbours, store: store)
            opened()
        case .notDownloaded, .failed:
            Task {
                guard let copy = await store.download(ref.file, in: ref.owner), isOnScreen, lastTapped == location else { return }
                show(copy, of: ref.file, among: neighbours, store: store)
                opened()
            }
        }
    }

    /// Share or Save, for a file not here yet once it downloads.
    func share(_ ref: MoodleFileRef, store: MoodleCourseStore) {
        let location = store.location(of: ref.file, in: ref.owner)
        lastTapped = location
        Task {
            guard let copy = await store.download(ref.file, in: ref.owner), isOnScreen, lastTapped == location else { return }
            share(copy)
        }
    }

    func share(_ item: URL) {
        #if os(iOS)
        shared = MoodleSharedItem(url: item)
        #else
        MacSharePicker.show(item)
        #endif
    }

    /// HTML and SVG go to the share sheet, never to Quick Look, as mail attachments do.
    private func show(_ copy: URL, of file: MoodleFile, among neighbours: [MoodleFileRef], store: MoodleCourseStore) {
        guard !file.opensInShareSheet else {
            share(copy)
            return
        }
        let downloaded = neighbours.compactMap { neighbour -> URL? in
            guard !neighbour.file.opensInShareSheet,
                  case .downloaded(let url) = store.downloadState(of: neighbour.file, in: neighbour.owner) else { return nil }
            return url
        }
        previewItems = downloaded.contains(copy) ? downloaded : downloaded + [copy]
        preview = copy
    }
}

/// A file or a link to hand to the share sheet.
struct MoodleSharedItem: Identifiable {
    let url: URL
    var id: URL { url }
}

extension MoodleFile {
    /// Quick Look renders HTML and SVG in the app with scripts on, which the mail screen keeps
    /// them from too (`swift/TigerDuck/Services/Mail/Rules/MailWarnings.swift`).
    nonisolated var opensInShareSheet: Bool {
        let type = mimeType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if type == "text/html" || type == "image/svg+xml" { return true }
        return ["html", "htm", "shtml", "xhtml", "mht", "mhtml", "svg"].contains((name as NSString).pathExtension.lowercased())
    }
}

extension View {
    /// Presents what `opener` opens: Quick Look, and on iOS the share sheet.
    func moodleFilePresentation(_ opener: MoodleFileOpener) -> some View {
        modifier(MoodleFilePresentation(opener: opener))
    }
}

private struct MoodleFilePresentation: ViewModifier {
    @Bindable var opener: MoodleFileOpener

    func body(content: Content) -> some View {
        content
            .quickLookPreview($opener.preview, in: opener.previewItems)
            #if os(iOS)
            .sheet(item: $opener.shared) { item in
                ShareSheet(url: item.url)
                    .presentationDetents([.medium, .large])
            }
            #endif
            .onAppear { opener.isOnScreen = true }
            .onDisappear { opener.isOnScreen = false }
    }
}

#if os(macOS)
/// The share menu at the pointer, where the menu that asked for it was.
private enum MacSharePicker {
    static func show(_ item: URL) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [item])
            .show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}
#endif
