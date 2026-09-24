#if os(iOS)
import Testing
import UIKit
@testable import TigerDuck

/// A library code already on screen belongs to whoever was signed in when it
/// was fetched. The in-flight guards stop a late one landing; this is the one
/// that had already landed.
@MainActor
struct LibraryViewModelAccountTests {
    @Test func anAccountChangeTakesTheCodeOffTheScreenAtOnce() {
        let model = LibraryViewModel()
        model.qrCodeImage = UIImage()
        model.qrPayload = "previous-account-code"
        model.isLoadingQR = true

        NotificationCenter.default.post(name: LibraryService.accountDidChange, object: nil)

        #expect(model.qrCodeImage == nil)
        #expect(model.qrPayload == nil)
        #expect(model.isLoadingQR == false)
    }

    @Test func otherNotificationsLeaveTheCodeAlone() {
        let model = LibraryViewModel()
        model.qrPayload = "code"
        NotificationCenter.default.post(name: Notification.Name("TigerDuck.somethingElse"), object: nil)
        #expect(model.qrPayload == "code")
    }
}
#endif
