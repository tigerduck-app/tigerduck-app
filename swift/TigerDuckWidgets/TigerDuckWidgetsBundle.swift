import WidgetKit
import SwiftUI

/// Widgets the TigerDuck Widgets extension surfaces.
///
/// iOS gets the full set (Today + Next Class + Week grid + Library QR
/// shortcut + lock-screen accessory variants). macOS surfaces Today,
/// Next Class, and Week — Library widgets are absent because the
/// underlying Library feature isn't surfaced in the Mac app; accessory
/// widgets are absent because lock-screen widget families don't exist
/// on macOS.
@main
struct TigerDuckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        NextClassWidget()
        WeekWidget()
        #if os(iOS)
        LibraryShortcutWidget()
        AccessoryWidget()
        #endif
    }
}
