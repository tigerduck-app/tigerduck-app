import Defaults
import Foundation
import SwiftUI

/// The account's club subscriptions: which clubs, in what priority, and the color of each. They
/// are not tied to a term, so they carry over to the next one. Each change is stamped, saved for
/// the sign-in it was made in, and handed to the sync through `onChange`.
@MainActor
@Observable
final class ClubSubscriptions: AccountScoped {
    static let shared = ClubSubscriptions()

    private(set) var document: ClubSubscriptionsDocument
    /// Runs after each change made on this device.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let palette: [UInt32]
    @ObservationIgnored private let now: () -> Date

    init(palette: [UInt32] = TigerDuckTheme.coursePaletteHexes, now: @escaping () -> Date = { Date() }) {
        self.palette = palette
        self.now = now
        document = Defaults[.clubSubscriptions].map(ClubSubscriptionsDocument.init(json:)) ?? ClubSubscriptionsDocument()
    }

    static func forgetAccount(in storage: AccountStorage) {
        Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
        shared.document = ClubSubscriptionsDocument()
    }

    /// The subscribed clubs, highest priority first.
    var subscribedIDs: [Int] { document.subscribedIDs }

    var hasSubscriptions: Bool { document.clubs.values.contains { $0.subscribed?.value == true } }

    func isSubscribed(_ id: Int) -> Bool { document.isSubscribed(id) }

    /// `0xRRGGBB`: the color picked or first given, or the club's default when there is none.
    func color(of id: Int) -> UInt32 {
        document.clubs[id]?.color?.value ?? Self.defaultColor(of: id, palette: palette)
    }

    func subscribe(_ id: Int, for signIn: SignIn) {
        let color = Self.defaultColor(of: id, palette: palette)
        change(for: signIn) { $0.subscribe(id, defaultColor: color, at: $1) }
    }

    func unsubscribe(_ id: Int, for signIn: SignIn) {
        change(for: signIn) { $0.unsubscribe(id, at: $1) }
    }

    /// Moves subscribed clubs as a list's `onMove` reports it, over `subscribedIDs`.
    func move(fromOffsets source: IndexSet, toOffset destination: Int, for signIn: SignIn) {
        var ids = subscribedIDs
        ids.move(fromOffsets: source, toOffset: destination)
        change(for: signIn) { $0.reorder(ids, at: $1) }
    }

    func setColor(_ color: UInt32, of id: Int, for signIn: SignIn) {
        change(for: signIn) { $0.setColor(color, of: id, at: $1) }
    }

    /// Whether a change made here has yet to reach the server.
    var hasUnsentChanges: Bool { Defaults[.clubSubscriptionsPushPending] }

    /// Takes the document as the server now holds it. A change made here since the sync read the
    /// device's copy is stamped later and stays; once the two agree, nothing is left to send.
    func adopt(_ synced: ClubSubscriptionsDocument, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        let merged = ClubSubscriptionsDocument.merged(local: document, server: synced)
        if merged != document { save(merged, for: signIn) }
        if merged == synced { Defaults[.clubSubscriptionsPushPending, for: signIn] = false }
    }

    /// 32-bit FNV-1a of the decimal id's UTF-8 bytes, modulo the palette, so that every device and
    /// the Android app give a club the same color.
    nonisolated static func defaultColor(of id: Int, palette: [UInt32]) -> UInt32 {
        palette[Int(TigerDuckTheme.fnv1a(String(id)) % UInt32(palette.count))]
    }

    private func change(
        for signIn: SignIn, _ edit: (inout ClubSubscriptionsDocument, ClubSubscriptionsDocument.Stamp) -> Void
    ) {
        guard signIn.isCurrent else { return }
        var next = document
        edit(&next, ClubSubscriptionsDocument.Stamp(now()))
        guard next != document else { return }
        save(next, for: signIn)
        Defaults[.clubSubscriptionsPushPending, for: signIn] = true
        onChange?()
    }

    private func save(_ next: ClubSubscriptionsDocument, for signIn: SignIn) {
        Defaults[.clubSubscriptions, for: signIn] = next.json()
        document = next
    }
}
