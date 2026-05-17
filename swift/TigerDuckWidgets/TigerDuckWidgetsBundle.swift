import WidgetKit
import SwiftUI

/// Widgets the TigerDuck Widgets extension surfaces.
///
/// iOS gets the full set (Today + Next Class + Week grid + Library QR
/// shortcut + lock-screen accessory variants). macOS is intentionally
/// scoped to just Today's Schedule and Next Class — the two widgets
/// the Mac users explicitly asked for. Library widgets are absent on
/// Mac because the underlying Library feature isn't surfaced in the
/// Mac app; accessory widgets are absent because lock-screen widget
/// families don't exist on macOS.
@main
struct TigerDuckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        NextClassWidget()
        #if os(iOS)
        WeekWidget()
        LibraryShortcutWidget()
        AccessoryWidget()
        #endif
    }
}
