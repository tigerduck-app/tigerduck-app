import Foundation
import Observation

/// The pin-mismatch prompt waiting to be shown: at most one at a time, each set at most once per
/// launch, and only while the app is in the foreground. After a Cancel the next launch asks again;
/// a prompt closed without an answer may be asked again once a browser opens. A mismatch from a
/// background request waits here for the next foreground.
@MainActor
@Observable
final class TLSPinMismatchQueue {
    static let shared = TLSPinMismatchQueue()

    private(set) var prompt: TLSPinMismatch?

    /// Set from the scene phase; a held mismatch shows once this turns true. A prompt still open
    /// as the app leaves goes back to held, so a document fetched meanwhile can still drop it.
    var isForeground = false {
        didSet {
            if !isForeground, let prompt {
                askedThisLaunch.remove(prompt.setID)
                held = prompt
                self.prompt = nil
            }
            surface()
        }
    }

    @ObservationIgnored private var held: TLSPinMismatch?
    @ObservationIgnored private var askedThisLaunch: Set<String> = []
    @ObservationIgnored private var closedUnanswered: Set<String> = []
    @ObservationIgnored private let engine: TLSPinEngine
    @ObservationIgnored private let afterContinue: @MainActor () -> Void

    init(engine: TLSPinEngine = .shared, afterContinue: (@MainActor () -> Void)? = nil) {
        self.engine = engine
        self.afterContinue = afterContinue ?? {
            #if os(iOS)
            TLSPinWatchBroadcaster.shared.broadcast()
            #endif
            NotificationCenter.default.post(name: AppConstants.tlsPinAcceptanceDidChange, object: nil)
        }
    }

    func report(_ mismatch: TLSPinMismatch) {
        guard prompt == nil, held == nil, !askedThisLaunch.contains(mismatch.setID) else { return }
        held = mismatch
        surface()
    }

    /// Trusts the shown chain's leaf and intermediates for its set until the build changes, then
    /// refreshes the way a return to the foreground does. A prompt the engine no longer allows,
    /// after a newer document or its expiry, closes with nothing stored.
    func `continue`() {
        guard let prompt else { return }
        self.prompt = nil
        guard engine.accept(prompt) else { return }
        afterContinue()
    }

    /// Stores nothing, and the set is not asked about again until the next launch.
    func cancel() {
        prompt = nil
    }

    /// The student closed the prompt without answering, as a swipe or Escape does: nothing is
    /// stored. A late close of a prompt the queue has since replaced changes nothing.
    func dismiss(_ shown: TLSPinMismatch) {
        guard prompt == shown else { return }
        closedUnanswered.insert(shown.setID)
        prompt = nil
    }

    /// A new browser, where the student reloads the refused page, lets each set closed without an
    /// answer be asked about again. Only a browser opening re-arms it, so requests that keep being
    /// refused cannot bring the prompt back the moment it closes.
    func offerDismissedAgain() {
        askedThisLaunch.subtract(closedUnanswered)
        closedUnanswered = []
    }

    /// A held mismatch the engine no longer allows a prompt for, after a newer document or its
    /// expiry, is dropped unasked.
    private func surface() {
        guard isForeground, prompt == nil, let held else { return }
        self.held = nil
        guard engine.isPromptable(held) else { return }
        askedThisLaunch.insert(held.setID)
        prompt = held
    }
}

extension TLSPinEngine {
    /// The app's document fetch and prompt queue. The Watch and the unit tests run without them.
    static func installAppHooks() {
        shared.installAppHooks(fetcher: .shared)
    }

    /// The refetch runs before onboarding too: a request the user started, such as onboarding's
    /// sign-in, triggers it, not launch code, and a fresh install whose built-in pins went stale
    /// has no other way to get the pins it needs to finish onboarding.
    func installAppHooks(fetcher: TLSPinDocumentFetcher) {
        install(
            refresh: { await fetcher.refetch() },
            report: { mismatch in
                Task { @MainActor in TLSPinMismatchQueue.shared.report(mismatch) }
            }
        )
    }
}
