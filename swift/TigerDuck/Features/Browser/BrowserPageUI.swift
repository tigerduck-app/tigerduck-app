import UIKit
import WebKit

@MainActor
final class BrowserPageUI: NSObject, WKUIDelegate {
    let dialogs = BrowserDialogs()
    private let openHere: (WKNavigationAction, WKWebView) -> Void
    private weak var webView: WKWebView?

    init(openHere: @escaping (WKNavigationAction, WKWebView) -> Void) {
        self.openHere = openHere
        super.init()
        dialogs.show = { [weak self] in self?.present($0) }
    }

    /// WebKit raises unless what the page still waits on is answered, and a deinit is not
    /// isolated to the main actor.
    deinit {
        Task { @MainActor [dialogs] in dialogs.cancelAll() }
    }

    /// A page opens an empty window to write into; loading one here would empty this page.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let address = action.request.url?.absoluteString ?? ""
        if !address.isEmpty, address != "about:blank" { openHere(action, webView) }
        return nil
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
    ) {
        ask(.alert, message, from: frame, in: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        ask(.confirm, message, from: frame, in: webView) { completionHandler($0 != nil) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        ask(.prompt(defaultText: defaultText ?? ""), prompt, from: frame, in: webView, reply: completionHandler)
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    /// A sandboxed frame's origin is opaque, with no host, and an address such as about:srcdoc has
    /// none either; Safari then names the page's host.
    private func ask(
        _ kind: BrowserDialogs.Dialog.Kind, _ message: String, from frame: WKFrameInfo, in webView: WKWebView,
        reply: @escaping BrowserDialogs.Reply
    ) {
        self.webView = webView
        let hosts = [
            frame.securityOrigin.host, frame.request.url?.host(percentEncoded: false), webView.url?.host(percentEncoded: false),
        ]
        let host = hosts.compactMap { $0 }.first { !$0.isEmpty } ?? ""
        dialogs.ask(BrowserDialogs.Dialog(kind: kind, host: host, message: message), reply: reply)
    }

    /// SwiftUI presents no alert while another presentation is up, nor once that one closes. UIKit
    /// presents nothing during a transition, drops a presentation it cannot make with only a console
    /// warning, and takes a web view under a full-screen presentation, as Quick Look's, out of its window.
    private func present(_ dialog: BrowserDialogs.Dialog) {
        guard dialog == dialogs.shown else { return }
        guard var top = webView?.window?.rootViewController else { return dialogs.answer(dialog, with: nil) }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        if let transition = top.transitionCoordinator {
            _ = transition.animate(alongsideTransition: nil) { [weak self] _ in self?.present(dialog) }
            return
        }
        let alert = alert(for: dialog)
        top.present(alert, animated: true)
        if alert.presentingViewController == nil { dialogs.answer(dialog, with: nil) }
    }

    private func alert(for dialog: BrowserDialogs.Dialog) -> UIAlertController {
        let alert = UIAlertController(title: dialog.host.isEmpty ? nil : dialog.host, message: dialog.message, preferredStyle: .alert)
        if case .prompt(let defaultText) = dialog.kind { alert.addTextField { $0.text = defaultText } }
        if dialog.kind != .alert {
            alert.addAction(UIAlertAction(title: String(localized: "action_cancel"), style: .cancel) { [dialogs] _ in
                dialogs.answer(dialog, with: nil)
            })
        }
        let ok = UIAlertAction(title: String(localized: "browser_dialog_ok"), style: .default) { [dialogs, weak alert] _ in
            dialogs.answer(dialog, with: alert?.textFields?.first?.text ?? "")
        }
        alert.addAction(ok)
        alert.preferredAction = ok
        return alert
    }
}
