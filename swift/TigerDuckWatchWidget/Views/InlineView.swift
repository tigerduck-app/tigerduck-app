import SwiftUI

struct InlineView: View {
    let entry: NextClassEntry

    var body: some View {
        Text(text)
            .containerBackground(.fill.tertiary, for: .widget)
    }

    private var text: String {
        if let c = entry.current {
            return "\(c.name) · \(c.endHHmm)"
        } else if let n = entry.next {
            return "\(n.name) · \(n.startHHmm)"
        } else {
            return String(localized: "watch_no_upcoming_classes")
        }
    }
}
