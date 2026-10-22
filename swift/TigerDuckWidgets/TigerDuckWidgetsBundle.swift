import WidgetKit
import SwiftUI

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
