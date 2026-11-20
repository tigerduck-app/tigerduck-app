import Foundation
import Testing
@testable import TigerDuck

private nonisolated final class SeriesRefusal: DemoRequestRefusal {
    static let series = SignInSeries()

    override class var signIns: SignInSeries { series }
}

@Suite("Demo account request refusal", .serialized)
@MainActor
struct DemoRequestRefusalTests {
    @Test("every session the app makes asks the demo refusal before anything else")
    func everySessionAsksTheRefusalFirst() {
        let sessions = [
            SchoolSessions.pinned(.ephemeral),
            NTUSTSessionManager.shared.session,
            MoodleWebserviceClient.session,
            SemesterCatalog.session,
            LibraryRequests.session,
            BackendClient.session,
            BackendClient.catalogSession,
            BackendClient.pinDocumentSession,
        ]

        for session in sessions {
            #expect(session.configuration.protocolClasses?.first == DemoRequestRefusal.self)
        }
    }

    @Test("during the demo a request fails before the network, one from a background task too, and after it goes out")
    func demoRequestsFailBeforeTheNetwork() async throws {
        let url = SettingsAPIStub.uniqueBaseURL().appendingPathComponent("refresh")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsAPIStub.self] + (configuration.protocolClasses ?? [])
        let session = URLSession(configuration: configuration.refusingDemoRequests(with: SeriesRefusal.self))
        defer { SeriesRefusal.series.end() }

        SeriesRefusal.series.startDemo()
        let refused = await Task.detached { () -> URLError.Code? in
            do {
                _ = try await session.data(from: url)
                return nil
            } catch {
                return (error as? URLError)?.code
            }
        }.value

        #expect(refused == .notConnectedToInternet)
        #expect(SettingsAPIStub.requests(for: url).isEmpty)

        SeriesRefusal.series.end()
        SettingsAPIStub.enqueue(SettingsAPIStub.StubResponse(statusCode: 200, body: Data()), for: url)
        let (_, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(SettingsAPIStub.requests(for: url).count == 1)
    }

    @Test("during the demo the refusal claims web requests only, not file or data URLs")
    func onlyWebRequestsAreRefused() throws {
        SeriesRefusal.series.startDemo()
        defer { SeriesRefusal.series.end() }

        #expect(SeriesRefusal.canInit(with: URLRequest(url: try #require(URL(string: "HTTPS://example.invalid")))))
        #expect(SeriesRefusal.canInit(with: URLRequest(url: try #require(URL(string: "http://example.invalid")))))
        #expect(!SeriesRefusal.canInit(with: URLRequest(url: try #require(URL(string: "data:text/plain,demo")))))
        #expect(!SeriesRefusal.canInit(with: URLRequest(url: URL.temporaryDirectory)))
    }
}
