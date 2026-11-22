import Testing
@testable import TigerDuck

struct PageZoomTests {
    @Test func mailTextSteps10PercentFrom50To200() {
        #expect(PageZoom.mail.larger(than: 100) == 110)
        #expect(PageZoom.mail.smaller(than: 100) == 90)
        #expect(PageZoom.mail.larger(than: 190) == 200)
        #expect(PageZoom.mail.larger(than: 200) == nil)
        #expect(PageZoom.mail.smaller(than: 50) == nil)
        #expect(PageZoom.mail.steps.count == 16)
    }

    @Test func aStoredTextSizeOffTheStepsIsHeldToTheEndsAndMovesToTheNextStep() {
        #expect(PageZoom.mail.clamped(900) == 200)
        #expect(PageZoom.mail.clamped(-5) == 50)
        #expect(PageZoom.mail.clamped(125) == 125)
        #expect(PageZoom.mail.larger(than: 125) == 130)
        #expect(PageZoom.mail.smaller(than: 125) == 120)
    }
}
