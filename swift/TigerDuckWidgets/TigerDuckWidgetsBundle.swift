import WidgetKit
import SwiftUI

@main
struct TigerDuckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LibraryShortcutWidget()
        NextClassWidget()
        TodayWidget()
        // Future tasks add: WeekWidget(), AccessoryWidget()
    }
}
