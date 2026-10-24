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

    /// What the prompt presents; nil while nothing is due or the app is in the background.
    private(set) var prompt: TLSPinMismatch?

    /// Set from the scene phase; a held mismatch shows once this turns true.
    var isForeground = false {
        didSet { surface() }
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
    /// refreshes the way a return to the foreground does.
    func `continue`() {
        guard let prompt else { return }
        engine.accept(prompt)
        self.prompt = nil
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

    private func surface() {
        guard isForeground, prompt == nil, let held else { return }
        askedThisLaunch.insert(held.setID)
        self.held = nil
        prompt = held
    }
}

extension TLSPinEngine {
    /// The app's document fetch and prompt queue. The Watch and the unit tests run without them.
    static func installAppHooks() {
        shared.install(
            refresh: { await TLSPinDocumentFetcher.shared.refetch() },
            report: { mismatch in
                Task { @MainActor in TLSPinMismatchQueue.shared.report(mismatch) }
            }
        )
    }
}
