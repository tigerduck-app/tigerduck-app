import Foundation
import Testing
@testable import TigerDuck

/// The API endpoint changes only once the user agrees, and every account is signed out before it
/// does, so no session reaches a server that did not issue it.
@MainActor
struct DebugEndpointViewModelTests {
    @MainActor
    private final class Backend {
        var stored: String?
        var events: [String] = []
    }

    private static let inUse = URL(string: "https://api.tigerduck.app/v3")!
    private static let other = URL(string: "https://other.example/v3")!

    private static func model(
        _ backend: Backend,
        checked: DebugEndpointStore.CheckResult = .accepted(other)
    ) -> DebugEndpointViewModel {
        DebugEndpointViewModel(backing: .init(
            currentOverride: { backend.stored },
            rejectedOverride: { nil },
            effectiveURL: { backend.stored.flatMap(URL.init(string:)) ?? inUse },
            check: { _ in checked },
            store: { url in
                backend.events.append("store \(url.absoluteString)")
                backend.stored = url.absoluteString
                return true
            },
            clear: {
                backend.events.append("clear")
                backend.stored = nil
            }
        ))
    }

    @Test("a checked endpoint waits for the user's answer, and nothing changes before it")
    func asksFirst() async {
        let backend = Backend()
        let model = Self.model(backend)
        model.draft = Self.other.absoluteString

        await model.save()

        #expect(model.pendingChange == .init(url: Self.other))
        #expect(backend.events.isEmpty)
        #expect(model.storedOverride == nil)
    }

    @Test("going ahead signs out of every account before the new endpoint is stored")
    func signsOutBeforeTheChange() async throws {
        let backend = Backend()
        let model = Self.model(backend)
        model.draft = Self.other.absoluteString
        await model.save()
        let change = try #require(model.pendingChange)

        await model.confirm(change) { backend.events.append("sign out") }

        #expect(backend.events == ["sign out", "store \(Self.other.absoluteString)"])
        #expect(model.storedOverride == Self.other.absoluteString)
        #expect(model.effectiveURL == Self.other.absoluteString)
        #expect(model.pendingChange == nil)
    }

    @Test("going back to the default asks too, and signs out before the endpoint is cleared")
    func resetAsksAndSignsOut() async throws {
        let backend = Backend()
        backend.stored = Self.other.absoluteString
        let model = Self.model(backend)

        model.resetToDefault()
        #expect(backend.events.isEmpty)
        let change = try #require(model.pendingChange)
        #expect(change == .init(url: nil))

        await model.confirm(change) { backend.events.append("sign out") }

        #expect(backend.events == ["sign out", "clear"])
        #expect(model.storedOverride == nil)
        #expect(model.effectiveURL == Self.inUse.absoluteString)
    }

    @Test("the endpoint in use already is saved without asking or signing out")
    func sameEndpointSavesAtOnce() async {
        let backend = Backend()
        let model = Self.model(backend, checked: .accepted(Self.inUse))
        model.draft = Self.inUse.absoluteString

        await model.save()

        #expect(model.pendingChange == nil)
        #expect(backend.events == ["store \(Self.inUse.absoluteString)"])
    }

    @Test("an endpoint the check turns down says why and asks nothing")
    func rejectedEndpoint() async {
        let backend = Backend()
        let model = Self.model(backend, checked: .rejected(.notTigerDuck))
        model.draft = Self.other.absoluteString

        await model.save()

        #expect(model.pendingChange == nil)
        #expect(model.validationError == String(localized: "settings_api_endpoint_error_not_backend"))
        #expect(backend.events.isEmpty)
    }
}
