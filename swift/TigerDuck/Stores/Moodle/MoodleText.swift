import Foundation

/// Moodle's HTML as the screens show it.
nonisolated enum MoodleText {
    static func markdown(fromHTML html: String) -> String {
        MoodleHTMLText.markdown(fromHTML: html)
    }

    static func plainText(fromHTML html: String) -> String {
        MoodleHTMLText.plainText(fromHTML: html)
    }
}

/// What a failed Moodle call tells the student.
nonisolated enum MoodleFailure {
    static func isNetworkError(_ error: any Error) -> Bool {
        if case MoodleWebserviceError.transientNetwork = error { return true }
        return error is URLError
    }

    static func isSiteMaintenance(_ error: any Error) -> Bool {
        if case MoodleWebserviceError.siteMaintenance = error { return true }
        return false
    }

    static func message(for error: any Error) -> String {
        isNetworkError(error) ? String(localized: "error_network_unavailable") : error.localizedDescription
    }
}
