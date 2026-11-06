import Foundation

/// WebKit raises unless each dialog is answered exactly once.
@MainActor
final class BrowserDialogs {
    struct Dialog: Equatable {
        enum Kind: Equatable {
            case alert, confirm
            case prompt(defaultText: String)
        }

        let id = UUID()
        let kind: Kind
        let host: String
        let message: String
    }

    /// The field's text for OK, empty but for a prompt; nil for Cancel.
    typealias Reply = @MainActor (_ text: String?) -> Void

    var show: (Dialog) -> Void = { _ in }
    private var waiting: [(dialog: Dialog, reply: Reply)] = []

    var shown: Dialog? { waiting.first?.dialog }

    func ask(_ dialog: Dialog, reply: @escaping Reply) {
        waiting.append((dialog, reply))
        if waiting.count == 1 { show(dialog) }
    }

    func answer(_ dialog: Dialog, with text: String?) {
        guard dialog == shown else { return }
        waiting.removeFirst().reply(text)
        if let next = shown { show(next) }
    }

    func cancelAll() {
        let replies = waiting.map { $0.reply }
        waiting = []
        for reply in replies { reply(nil) }
    }
}
