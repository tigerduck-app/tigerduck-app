#if os(iOS) && DEBUG
import Foundation
import Testing
@testable import TigerDuck

extension LibrarySignInTests {
    nonisolated static let failingModes: [SimulatedFailure] = [.timeout, .http500, .http401, .http403, .unreachable]

    private static func expected(_ failure: SimulatedFailure) -> (waits: [Duration], error: URLError.Code?) {
        switch failure {
        case .none: ([], nil)
        case .timeout: ([.seconds(30)], .timedOut)
        case .http500: ([], .badServerResponse)
        case .http401: ([], .userAuthenticationRequired)
        case .http403: ([], .noPermissionsToReadFile)
        case .slow: ([.seconds(10)], nil)
        case .unreachable: ([], .cannotConnectToHost)
        }
    }

    private static func simulating(
        _ failure: SimulatedFailure, _ body: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> (waits: [Duration], error: URLError.Code?) {
        let simulator = ServerFailureSimulator()
        let sleeper = ManualSleeper()
        simulator.failures[.library] = failure
        simulator.sleep = { await sleeper.sleep(for: $0) }
        let run = Task { try await ServerFailureSimulator.$sharedForTesting.withValue(simulator) { try await body() } }
        if !expected(failure).waits.isEmpty {
            try await sleeper.waitUntilArmed()
            await sleeper.fire()
        }
        let thrown: URLError.Code?
        do {
            try await run.value
            thrown = nil
        } catch {
            thrown = try #require(error as? URLError).code
        }
        return (await sleeper.requestedDurations, thrown)
    }

    @Test(arguments: SimulatedFailure.allCases)
    func aSimulatedLibraryModeWaitsAndFailsAsItsLabelSays(_ failure: SimulatedFailure) async throws {
        let outcome = try await Self.simulating(failure) { try await ServerFailureSimulator.shared.check(.library) }
        #expect(outcome.waits == Self.expected(failure).waits)
        #expect(outcome.error == Self.expected(failure).error)
    }

    /// Nothing reached the library, so even a simulated 401 or 403 is no refusal of the password.
    @Test(arguments: failingModes)
    func aSimulatedFailureOfTheSignInLeavesTheStoredPasswordUnrefused(_ failure: SimulatedFailure) async throws {
        try await Self.withStoredAccount { _ in
            let epoch = Self.watchEpoch
            let outcome = try await Self.simulating(failure) { _ = try await LibraryService.ensureToken() }
            #expect(outcome.waits == Self.expected(failure).waits)
            #expect(outcome.error == Self.expected(failure).error)
            #expect(LibraryService.storedPasswordRefusals.count == 0)
            #expect(LibraryService.storedPasswordRetry == nil)
            #expect(LibraryService.canSignInWithStoredCredentials)
            #expect(Self.watchEpoch == epoch)
            _ = try await LibraryService.ensureToken { _, _ in Self.answer() }
        }
    }

    @Test(arguments: failingModes)
    func aSimulatedFailureFailsTheCodeRequest(_ failure: SimulatedFailure) async throws {
        let keychain = MemoryKeychain.locked()
        let expiry = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
        try keychain.setObject(Data("token".utf8), forKey: AppConstants.KeychainKeys.libraryToken)
        try keychain.setObject(Data(String(expiry).utf8), forKey: AppConstants.KeychainKeys.libraryTokenExpiry)
        let outcome = try await SecureStore.$sharedForTesting.withValue(keychain) {
            try await Self.simulating(failure) { _ = try await LibraryService.generateQRCode() }
        }
        #expect(outcome.waits == Self.expected(failure).waits)
        #expect(outcome.error == Self.expected(failure).error)
    }
}
#endif
