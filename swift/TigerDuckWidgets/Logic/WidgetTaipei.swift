import Foundation

enum WidgetTaipei {
    static let timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }()
}
