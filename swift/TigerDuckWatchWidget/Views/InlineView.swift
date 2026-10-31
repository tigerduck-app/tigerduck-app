import SwiftUI
import WidgetKit
import TigerDuckCore

struct InlineView: View {
    let entry: NextClassEntry

    var body: some View {
        Text(text)
            .containerBackground(.fill.tertiary, for: .widget)
    }

    var text: String {
        if let c = entry.current {
            return "\(c.name) · \(c.endHHmm)"
        } else if let n = entry.next {
            return "\(n.name) · \(entry.nextDay.inlineCaption(n.startHHmm, in: entry.language))"
        } else {
            return entry.language.string("watch_no_upcoming_classes")
        }
    }
}
