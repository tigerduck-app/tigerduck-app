import SwiftUI

struct CircularView: View {
    let entry: NextClassEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Text(monogram)
                .font(.headline)
                .widgetAccentable()
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var monogram: String {
        guard let course = entry.current ?? entry.next else { return "—" }
        let name = course.name
        if name.isEmpty { return "?" }
        return String(name.prefix(2))
    }
}
