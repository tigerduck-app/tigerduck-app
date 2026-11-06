import UIKit

/// SwiftUI has no quick action callback. iOS hands a chosen Home Screen quick action to the window
/// scene's delegate: in the connection options when it launches the app for it, and through
/// `windowScene(_:performActionFor:completionHandler:)` when the app is already running (Apple's
/// "Add Home Screen quick actions").
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let item = connectionOptions.shortcutItem {
            Self.open(item)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(Self.open(shortcutItem))
    }

    @discardableResult
    static func open(_ item: UIApplicationShortcutItem, with open: @MainActor (URL) -> Void = { AppLink.open($0) }) -> Bool {
        guard let url = URL(string: item.type) else { return false }
        open(url)
        return true
    }
}
