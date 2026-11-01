import Foundation
import Observation

/// The pin-mismatch prompt waiting to be shown: at most one at a time, each set at most once per
/// launch and not within an hour of a Cancel for it, and only while the app is in the foreground.
/// A mismatch from a background request waits here for the next foreground.
@MainActor
@Observable
final class TLSPinMismatchQueue {
    static let shared = TLSPinMismatchQueue()
    static let quietPeriod: TimeInterval = 60 * 60
    private static let quietUntilKey = "tlsPinPromptQuietUntil"

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
    @ObservationIgnored private let engine: TLSPinEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let afterContinue: @MainActor () -> Void

    init(
        engine: TLSPinEngine = .shared,
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = { Date() },
        afterContinue: (@MainActor () -> Void)? = nil
    ) {
        self.engine = engine
        self.defaults = defaults
        self.clock = clock
        self.afterContinue = afterContinue ?? {
            #if os(iOS)
            TLSPinWatchBroadcaster.shared.broadcast()
            #endif
            NotificationCenter.default.post(name: AppConstants.tlsPinAcceptanceDidChange, object: nil)
        }
    }

    func report(_ mismatch: TLSPinMismatch) {
        guard prompt == nil, held == nil,
              !askedThisLaunch.contains(mismatch.setID),
              clock() >= quietUntil(mismatch.setID) else { return }
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

    func cancel() {
        guard let prompt else { return }
        var quiet = defaults.dictionary(forKey: Self.quietUntilKey) as? [String: Double] ?? [:]
        quiet[prompt.setID] = clock().addingTimeInterval(Self.quietPeriod).timeIntervalSince1970
        defaults.set(quiet, forKey: Self.quietUntilKey)
        self.prompt = nil
    }

    private func quietUntil(_ setID: String) -> Date {
        let quiet = defaults.dictionary(forKey: Self.quietUntilKey) as? [String: Double]
        return Date(timeIntervalSince1970: quiet?[setID] ?? 0)
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
