#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct BrowserDownloadsTests {
    private static let request = URLRequest(url: URL(string: "https://moodle2.ntust.edu.tw/pluginfile.php/1/mod_resource/content/1/week3.pptx")!)

    private static func downloads(_ place: SavedDownloadsTests.Place) -> BrowserDownloads {
        BrowserDownloads(store: place.store, folder: place.root.appending(path: "page", directoryHint: .isDirectory))
    }

    @Test func aNewDownloadIsFirstAndRunning() {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        _ = downloads.start("a.pdf", request: Self.request) {}
        let second = downloads.start("b.pdf", request: Self.request) {}

        #expect(downloads.items.map(\.name) == ["b.pdf", "a.pdf"])
        #expect(downloads.items.first?.id == second)
        #expect(downloads.items.allSatisfy { $0.state == .running })
    }

    @Test func progressShowsOnceItMovesAPercentOrAHundredKilobytes() {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        let known = downloads.start("known.pdf", request: Self.request) {}
        let unknown = downloads.start("unknown.zip", request: Self.request) {}

        downloads.received(known, bytes: 50_000, of: 20_000_000)
        downloads.received(known, bytes: 199_999, of: 20_000_000)
        downloads.received(unknown, bytes: 99_999, of: nil)
        #expect(downloads.item(known)?.received == 0)
        #expect(downloads.item(known)?.expected == 20_000_000)
        #expect(downloads.item(unknown)?.received == 0)

        downloads.received(known, bytes: 200_000, of: 20_000_000)
        downloads.received(unknown, bytes: 100_000, of: nil)
        #expect(downloads.item(known)?.received == 200_000)
        #expect(downloads.item(unknown)?.received == 100_000)

        downloads.received(known, bytes: 20_000_000, of: 20_000_000)
        #expect(downloads.item(known)?.received == 20_000_000)
    }

    @Test func theMenuRingShowsTheShareOfWhatIsRunning() {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        #expect(downloads.runningShare == nil)

        let first = downloads.start("a.pdf", request: Self.request) {}
        let second = downloads.start("b.pdf", request: Self.request) {}
        #expect(downloads.runningShare == 0)
        downloads.received(first, bytes: 3_000_000, of: 4_000_000)
        downloads.received(second, bytes: 0, of: 4_000_000)
        #expect(downloads.runningShare == 0.375)

        #expect(downloads.fail(second))
        #expect(downloads.runningShare == 0.75)
    }

    @Test func aFinishedDownloadMovesIntoTheFolderAndLeavesTheList() async throws {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        let id = downloads.start("講義.pdf", request: Self.request) {}

        let saved = try #require(await downloads.finish(id, file: try place.download("slides")))

        #expect(saved == place.folder.appending(path: "講義.pdf"))
        #expect(downloads.items.isEmpty)
        #expect(downloads.saved.map(\.name) == ["講義.pdf"])
        #expect(try await place.store.entries().map(\.name) == ["講義.pdf"])
    }

    @Test func aDownloadThatCannotBeMovedFails() async throws {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        let id = downloads.start("講義.pdf", request: Self.request) {}

        let saved = await downloads.finish(id, file: place.root.appending(path: "gone.pdf"))

        #expect(saved == nil)
        #expect(downloads.item(id)?.state == .failed)
        #expect(downloads.saved.isEmpty)
    }

    @Test func aCancelStopsTheDownloadAndItsFailureIsNotShown() {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        var cancelled = 0
        let id = downloads.start("a.pdf", request: Self.request) { cancelled += 1 }

        downloads.cancel(id)

        #expect(cancelled == 1)
        #expect(downloads.items.isEmpty)
        #expect(!downloads.fail(id))
    }

    @Test func aFailureKeepsTheRequestForARetry() {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        let id = downloads.start("a.pdf", request: Self.request) {}

        #expect(downloads.fail(id))

        #expect(downloads.item(id)?.state == .failed)
        #expect(downloads.item(id)?.request == Self.request)
        #expect(downloads.canClear)
    }

    @Test func aRetryForgetsTheFailedRowsOfItsRequestOnly() {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        let other = URLRequest(url: URL(string: "https://moodle2.ntust.edu.tw/pluginfile.php/2/mod_resource/content/1/other.pdf")!)
        _ = downloads.fail(downloads.start("week3.pptx", request: Self.request) {})
        let otherFailure = downloads.start("other.pdf", request: other) {}
        _ = downloads.fail(otherFailure)
        let running = downloads.start("week3.pptx", request: Self.request) {}

        downloads.forgetFailures(of: Self.request)

        #expect(downloads.items.map(\.id) == [running, otherFailure])
    }

    @Test func clearingDeletesSavedFilesAndFailuresButKeepsWhatIsRunning() async throws {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        _ = try place.usersOwn("mine", named: "mine.pdf")
        let done = downloads.start("done.pdf", request: Self.request) {}
        _ = await downloads.finish(done, file: try place.download("done"))
        let failed = downloads.start("failed.pdf", request: Self.request) {}
        _ = downloads.fail(failed)
        let running = downloads.start("running.pdf", request: Self.request) {}

        await downloads.clear()

        #expect(downloads.items.map(\.id) == [running])
        #expect(downloads.saved.isEmpty)
        #expect(!downloads.canClear)
        #expect(!place.exists("done.pdf"))
        #expect(place.exists("mine.pdf"))
    }

    @Test func aRemovedFileLeavesTheFolderAndTheList() async throws {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        let downloads = Self.downloads(place)
        _ = await downloads.finish(downloads.start("a.pdf", request: nil) {}, file: try place.download("a"))
        _ = await downloads.finish(downloads.start("b.pdf", request: nil) {}, file: try place.download("b"))
        let first = try #require(downloads.saved.first { $0.name == "a.pdf" })

        await downloads.remove(first)

        #expect(downloads.saved.map(\.name) == ["b.pdf"])
        #expect(!place.exists("a.pdf"))
    }

    @Test func theListReadsWhatEarlierPagesSaved() async throws {
        let place = SavedDownloadsTests.Place()
        defer { place.remove() }
        _ = try await place.store.save(try place.download("a"), as: "earlier.pdf")
        let downloads = Self.downloads(place)
        #expect(downloads.saved.isEmpty)

        await downloads.reload()

        #expect(downloads.saved.map(\.name) == ["earlier.pdf"])
    }
}

@MainActor
struct FilesFolderOpenerTests {
    private static let folder = URL(filePath: "/var/mobile/Containers/Data/Application/0A1B/Documents/", directoryHint: .isDirectory)

    @Test func theFilesAppOpensAtTheFolderWhenItAnswersTheLink() async {
        let opened = Opened()
        let opener = FilesFolderOpener(canOpen: { _ in true }, open: { await opened.add($0); return true })

        #expect(await opener.route(to: Self.folder) == .filesApp)
        #expect(await opened.urls.map(\.absoluteString) == ["shareddocuments:///var/mobile/Containers/Data/Application/0A1B/Documents/"])
    }

    @Test func thePickerStartedInTheFolderShowsWhenNoAppAnswersTheLink() async {
        let opened = Opened()
        let opener = FilesFolderOpener(canOpen: { _ in false }, open: { await opened.add($0); return true })

        #expect(await opener.route(to: Self.folder) == .picker)
        #expect(await opened.urls.isEmpty)
    }

    @Test func thePickerShowsWhenTheFilesAppRefusesToOpen() async {
        let opener = FilesFolderOpener(canOpen: { _ in true }, open: { _ in false })

        #expect(await opener.route(to: Self.folder) == .picker)
    }

    private actor Opened {
        var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
    }
}
#endif
