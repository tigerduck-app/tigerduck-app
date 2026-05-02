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
                    event.request?.url = scrubSensitive(url)
                }
                return event
            }
            // Performance spans auto-instrumented from URLSession store the
            // request URL under `url` and the query string under `http.query`;
            // without this hook session-scoped params bypass beforeSend.
            options.beforeSendSpan = { span in
                for key in ["url", "http.url", "http.query"] {
                    guard let value = span.data[key] as? String else { continue }
                    let scrubbed = scrubSensitive(value)
                    if scrubbed != value {
                        span.setData(value: scrubbed, key: key)
                    }
                }
                return span
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
        crumb.message = scrubSensitive(message)
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Scrub credential-bearing tokens from any string before it leaves
    /// the device. Covers query-string tokens (`token=`, `wstoken=`),
    /// path-style Moodle tokens (`/wstoken/<...>`), OIDC password POST
    /// bodies (`Password=` / `password=`) and `Authorization: Bearer ...`
    /// headers that might be threaded into URLError userInfo or
    /// breadcrumbs.
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
        ScrubPattern(pattern: #"(wstoken|token)=[^&\s"']+"#, replacement: "$1=***"),
        ScrubPattern(pattern: #"/wstoken/[A-Za-z0-9+/=_-]+"#, replacement: "/wstoken/***"),
        ScrubPattern(pattern: #"(password|passwd|pwd)=[^&\s"']+"#, replacement: "$1=***"),
        ScrubPattern(pattern: #"Bearer\s+[A-Za-z0-9._\-+/=]+"#, replacement: "Bearer ***"),
        ScrubPattern(pattern: #"X-Push-Token:\s*\S+"#, replacement: "X-Push-Token: ***"),
    ]
}
