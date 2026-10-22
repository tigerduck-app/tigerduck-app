import WidgetKit
import SwiftUI

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
