import Foundation
import os

nonisolated enum AppLogger {
    private static let subsystem = "org.ntust.app.TigerDuck"

    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let moodle = Logger(subsystem: subsystem, category: "Moodle")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
    /// The category `swift/Shared/TLSPins/` logs under, so one filter shows the whole pin flow.
    static let tlsPins = Logger(subsystem: subsystem, category: "Security.TLSPin")
    private static let diagnostics = Logger(subsystem: subsystem, category: "Diagnostics")

    static func captureError(_ error: any Error, context: [String: String] = [:]) {
        diagnostics.error("\(errorLine(error, context: context), privacy: .private)")
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static func breadcrumb(_ message: String, category: String) {
        diagnostics.info("\(category, privacy: .public): \(scrubSensitive(message), privacy: .private)")
    }

    static func errorLine(_ error: any Error, context: [String: String]) -> String {
        let fields = context.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let line = fields.isEmpty
            ? String(reflecting: error)
            : "\(fields.joined(separator: " ")): \(String(reflecting: error))"
        return scrubSensitive(line)
    }

    static func scrubSensitive(_ value: String) -> String {
        var out = value
        for pattern in scrubPatterns {
            out = out.replacingOccurrences(
                of: pattern.pattern,
                with: pattern.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    private struct ScrubPattern {
        let pattern: String
        let replacement: String
    }

    private static let scrubPatterns: [ScrubPattern] = [
        ScrubPattern(pattern: #"([a-z][a-z0-9+.-]*://[^\s?#"']*)\?[^\s#"']+"#, replacement: "$1?***"),
        ScrubPattern(pattern: #"(wstoken|token)=[^&\s"']+"#, replacement: "$1=***"),
        ScrubPattern(pattern: #"/wstoken/[A-Za-z0-9+/=_-]+"#, replacement: "/wstoken/***"),
        ScrubPattern(pattern: #"/tokenpluginfile\.php/(?!wstoken/)[^/\s?#"']+"#, replacement: "/tokenpluginfile.php/***"),
        ScrubPattern(pattern: #"(password|passwd|pwd)=[^&\s"']+"#, replacement: "$1=***"),
        ScrubPattern(pattern: #"Bearer\s+[A-Za-z0-9._\-+/=]+"#, replacement: "Bearer ***"),
    ]
}
