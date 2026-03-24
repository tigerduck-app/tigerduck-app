import Foundation

enum AppConstants {
    static let appName = "TigerDuck"

    static let dataDidUpdate = Notification.Name("TigerDuck.dataDidUpdate")

    enum Periods {
        static let defaultVisible = ["1", "2", "3", "4", "6", "7", "8", "9"]
        static let extended = ["5", "10", "A", "B", "C", "D"]
        /// Chronological order of all periods (for sorting)
        static let chronologicalOrder = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "A", "B", "C", "D"]
        static let weekdays = ["一", "二", "三", "四", "五"]
        static let weekendDays = ["六", "日"]
    }

    enum PeriodTimes {
        static let mapping: [String: (start: String, end: String)] = [
            "1": ("08:10", "09:00"),
            "2": ("09:10", "10:00"),
            "3": ("10:20", "11:10"),
            "4": ("11:20", "12:10"),
            "5": ("12:20", "13:10"),
            "6": ("13:20", "14:10"),
            "7": ("14:20", "15:10"),
            "8": ("15:30", "16:20"),
            "9": ("16:30", "17:20"),
            "10": ("17:30", "18:20"),
            "A": ("18:30", "19:20"),
            "B": ("19:25", "20:15"),
            "C": ("20:15", "21:05"),
            "D": ("21:10", "22:00"),
        ]
    }
}
