import QuickLook
import SwiftUI

extension View {
    func filePreview(_ url: Binding<URL?>, in items: [URL] = []) -> some View {
        modifier(FilePreview(url: url, items: items))
    }
}

private struct FilePreview: ViewModifier {
    @Binding var url: URL?
    let items: [URL]
    #if os(iOS)
    @State private var opened: OpenedArchive?
    @State private var session: URL?
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .quickLookPreview(quickLook, in: quickLookItems)
            .onChange(of: url, initial: true) { _, url in
                guard let url, ArchiveFormats.isArchive(url), opened?.url != url else { return }
                let archive = ArchiveCache.shared.open(url)
                session = archive.session
                opened = archive
            }
            .fullScreenCover(item: $opened, onDismiss: closed) { archive in
                ArchiveBrowser(archive: archive.url, session: archive.session)
            }
        #else
        content.quickLookPreview($url, in: items)
        #endif
    }

    #if os(iOS)
    private var quickLook: Binding<URL?> {
        Binding(get: { url.flatMap { ArchiveFormats.isArchive($0) ? nil : $0 } }, set: { url = $0 })
    }

    private var quickLookItems: [URL] {
        let files = items.filter { !ArchiveFormats.isArchive($0) }
        guard let shown = quickLook.wrappedValue, !files.contains(shown) else { return files }
        return files + [shown]
    }

    private func closed() {
        if let session { ArchiveCache.shared.remove(session) }
        session = nil
        url = nil
    }
    #endif
}
