import Foundation
import Sentry
import os

enum AppLogger {
    private static let subsystem = "org.ntust.app.TigerDuck"

    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let moodle = Logger(subsystem: subsystem, category: "Moodle")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")

    static func start() {
        let dsn = (Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        SentrySDK.start { options in
            options.dsn = (dsn?.isEmpty == false) ? dsn : nil
            options.debug = false
            options.tracesSampleRate = 0.2
            options.sendDefaultPii = false
            options.beforeSend = { event in
                if let url = event.request?.url {
                    event.request?.url = url.replacingOccurrences(
                        of: #"token=[^&]+"#,
                        with: "token=***",
                        options: .regularExpression
                    )
                }

                return event
            }
        }
    }

    static func captureError(_ error: any Error, context: [String: String] = [:]) {
        for (key, value) in context.sorted(by: { $0.key < $1.key }) {
            breadcrumb("\(key)=\(value)", category: "context")
        }

        SentrySDK.capture(error: error)
    }

    static func breadcrumb(_ message: String, category: String, level: SentryLevel = .info) {
        let crumb = Breadcrumb()
        crumb.level = level
        crumb.category = category
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }
}
