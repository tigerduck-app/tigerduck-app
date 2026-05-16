import Foundation
import os

/// Wraps `os.Logger` for the watch app. Mirrors the phone's `AppLogger`
/// surface so call sites read the same way across targets.
enum WatchAppLogger {
    static let app = Logger(subsystem: "org.ntust.app.TigerDuck.watchkitapp", category: "app")
    static let wc = Logger(subsystem: "org.ntust.app.TigerDuck.watchkitapp", category: "wc")
    static let widget = Logger(subsystem: "org.ntust.app.TigerDuck.watchkitapp", category: "widget")
}
