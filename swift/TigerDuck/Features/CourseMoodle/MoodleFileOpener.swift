import QuickLook
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

nonisolated struct MoodleFileRef: Hashable, Sendable {
    let file: MoodleFile
    let owner: MoodleFileOwner
}

extension MoodleMaterial {
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

@Observable
@MainActor
final class MoodleFileOpener {
    var preview: URL?
    private(set) var previewItems: [URL] = []
    var shared: MoodleSharedItem?
    @ObservationIgnored var isOnScreen = false
    @ObservationIgnored private var latestAction = 0

    func tap(
        _ ref: MoodleFileRef,
        among neighbours: [MoodleFileRef],
        store: MoodleCourseStore,
        opened: @escaping () -> Void = {}
    ) {
        let action = nextAction()
        switch store.downloadState(of: ref.file, in: ref.owner) {
        case .downloading:
            store.cancelDownload(of: ref.file, in: ref.owner)
        case .downloaded(let copy):
            show(copy, of: ref.file, among: neighbours, store: store)
            opened()
        case .notDownloaded, .failed:
            Task {
                guard let copy = await store.download(ref.file, in: ref.owner), isLatest(action) else { return }
                show(copy, of: ref.file, among: neighbours, store: store)
                opened()
            }
        }
    }

    func share(_ ref: MoodleFileRef, store: MoodleCourseStore) {
        let action = nextAction()
        Task {
            guard let copy = await store.download(ref.file, in: ref.owner), isLatest(action) else { return }
            present(copy)
        }
    }

    func share(link: URL) {
        _ = nextAction()
        present(link)
    }

    func forgetPendingOpen() {
        _ = nextAction()
    }

    private func nextAction() -> Int {
        latestAction += 1
        return latestAction
    }

    private func isLatest(_ action: Int) -> Bool {
        isOnScreen && latestAction == action
    }

    private func present(_ item: URL) {
        #if os(iOS)
        shared = MoodleSharedItem(url: item)
        #else
        MacSharePicker.show(item)
        #endif
    }

    private func show(_ copy: URL, of file: MoodleFile, among neighbours: [MoodleFileRef], store: MoodleCourseStore) {
        guard !file.opensInShareSheet else {
            present(copy)
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

struct MoodleSharedItem: Identifiable {
    let url: URL
    var id: URL { url }
}

extension MoodleFile {
    nonisolated var opensInShareSheet: Bool {
        let type = mimeType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if type == "text/html" || type == "image/svg+xml" { return true }
        return ["html", "htm", "shtml", "xhtml", "mht", "mhtml", "svg"].contains((name as NSString).pathExtension.lowercased())
    }
}

extension View {
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
private enum MacSharePicker {
    static func show(_ item: URL) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [item])
            .show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}
#endif
