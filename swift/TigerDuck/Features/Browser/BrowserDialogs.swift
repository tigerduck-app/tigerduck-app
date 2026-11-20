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

    /// nil for Cancel; for OK, the prompt field's text, or "" for an alert or a confirm.
    typealias Reply = @MainActor (_ text: String?) -> Void

    /// A form asks a confirm and an alert or two in a row; a page looping on alert() never stops.
    static let dialogsInARow = 3
    /// A page asking again this soon after an answer leaves no moment to reach the browser's close button.
    static let inARowGap: Duration = .seconds(2)

    var show: (Dialog) -> Void = { _ in }
    var now: () -> ContinuousClock.Instant = { .now }
    private var waiting: [(dialog: Dialog, reply: Reply)] = []
    private var lastAnswer: ContinuousClock.Instant?
    private var inARow = 0
    private var isMuted = false

    var shown: Dialog? { waiting.first?.dialog }

    func ask(_ dialog: Dialog, reply: @escaping Reply) {
        let followsOn = !waiting.isEmpty || lastAnswer.map { now() - $0 < Self.inARowGap } ?? false
        inARow = followsOn ? inARow + 1 : 1
        if inARow > Self.dialogsInARow { isMuted = true }
        guard !isMuted else { return reply(nil) }
        waiting.append((dialog, reply))
        if waiting.count == 1 { show(dialog) }
    }

    func answer(_ dialog: Dialog, with text: String?) {
        guard dialog == shown else { return }
        lastAnswer = now()
        waiting.removeFirst().reply(text)
        if let next = shown { show(next) }
    }

    func pageChanged() {
        lastAnswer = nil
        inARow = 0
        isMuted = false
    }

    func cancelAll() {
        let replies = waiting.map { $0.reply }
        waiting = []
        for reply in replies { reply(nil) }
    }
}
