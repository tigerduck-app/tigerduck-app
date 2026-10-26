#if os(iOS)
import Defaults
import Foundation
import Testing
@testable import TigerDuck

struct BrowserSitesTests {
    @Test func zoomStepsUpAndDownAndStopsAtTheEnds() {
        #expect(BrowserZoom.larger(than: 100) == 115)
        #expect(BrowserZoom.smaller(than: 100) == 85)
        #expect(BrowserZoom.larger(than: 200) == nil)
        #expect(BrowserZoom.smaller(than: 50) == nil)
    }

    @Test func aZoomBetweenStepsGoesToTheNearestStepThatWay() {
        #expect(BrowserZoom.larger(than: 110) == 115)
        #expect(BrowserZoom.smaller(than: 110) == 100)
    }

    @Test func eachSiteKeepsItsOwnZoomAndAHundredLeavesNoEntry() {
        var sites = BrowserSites()
        sites.setZoom(150, for: "Moodle2.ntust.edu.tw")
        #expect(sites.zoom(for: "moodle2.ntust.edu.tw") == 150)
        #expect(sites.zoom(for: "i.ntust.edu.tw") == 100)

        sites.setZoom(100, for: "moodle2.ntust.edu.tw")
        #expect(sites.zoom.isEmpty)
    }

    @Test func aStoredZoomOutsideTheStepsIsHeldToThem() {
        let sites = BrowserSites(zoom: ["a.ntust.edu.tw": 900, "b.ntust.edu.tw": 10])
        #expect(sites.zoom(for: "a.ntust.edu.tw") == 200)
        #expect(sites.zoom(for: "b.ntust.edu.tw") == 50)
    }

    @Test func eachSiteKeepsItsOwnDesktopChoice() {
        var sites = BrowserSites()
        sites.setDesktop(true, for: "MOODLE2.ntust.edu.tw")
        #expect(sites.isDesktop("moodle2.ntust.edu.tw"))
        #expect(!sites.isDesktop("i.ntust.edu.tw"))

        sites.setDesktop(false, for: "moodle2.ntust.edu.tw")
        #expect(sites.desktop.isEmpty)
    }

    @MainActor
    @Test func aResetForgetsEverySitesZoomAndDesktopChoice() {
        defer { Defaults.reset(.browserZoom, .browserDesktopSites) }
        BrowserSites.stored = BrowserSites(zoom: ["moodle2.ntust.edu.tw": 150], desktop: ["moodle2.ntust.edu.tw"])
        let data = BrowserData(loadState: { .empty }, saveState: { _ in }, remove: { true }, clear: {})

        data.reset()

        #expect(BrowserSites.stored == BrowserSites())
    }

    @MainActor
    @Test func clearingFromStorageKeepsEverySitesZoomAndDesktopChoice() {
        defer { Defaults.reset(.browserZoom, .browserDesktopSites) }
        let choices = BrowserSites(zoom: ["moodle2.ntust.edu.tw": 150], desktop: ["moodle2.ntust.edu.tw"])
        BrowserSites.stored = choices
        let data = BrowserData(loadState: { .empty }, saveState: { _ in }, remove: { true }, clear: {})

        data.reset(keepingSiteChoices: true)

        #expect(BrowserSites.stored == choices)
        #expect(data.generation == 1)
    }
}

@MainActor
struct BrowserZoomPeekTests {
    @Test func aZoomFadesTheSheetForAMomentAndKeepsTheCopyUntilTheSheetIsBack() async throws {
        let peek = BrowserZoomPeek()
        var changes = 0
        peek.zoom { changes += 1 }
        #expect(changes == 1 && peek.isPeeking && peek.showsCopy)

        peek.sheetShown()
        #expect(peek.showsCopy, "a fade back that another zoom cut short leaves the copy")
        try await waitUntil(timeout: .seconds(5)) { !peek.isPeeking }
        #expect(peek.showsCopy)
        peek.sheetShown()
        #expect(!peek.showsCopy)
    }

    @Test func closingTheSheetEndsThePeek() {
        let peek = BrowserZoomPeek()
        peek.zoom {}
        peek.stop()
        #expect(!peek.isPeeking && !peek.showsCopy)
    }
}
#endif
