#if os(iOS)
import Foundation
import Network
import Security
import Testing
@testable import TigerDuck

/// The pin check runs inside the TLS handshake, so a refused chain never carries a request byte.
/// The server is in-process and presents the hand-made `localhost` chain.
@Suite(.serialized)
struct TLSPinNoRequestBytesTests {
    typealias F = TLSPinFixtures

    private func fetch(pinning pin: String) async throws -> (succeeded: Bool, received: Data) {
        let server = try LocalTLSServer()
        let port = try await server.start()
        defer { server.stop() }
        let engine = F.engine(builtIn: [
            TLSPinSet(id: "test", domains: [.init(name: "localhost", includeSubdomains: false)],
                      pins: [pin], expiresAt: .distantFuture),
        ])
        let delegate = TLSPinningDelegate(
            engine: engine, testAnchors: [F.testRoot], verifyDate: F.testLeafNotBefore.addingTimeInterval(F.day)
        )
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://localhost:\(port)/"))
        let succeeded = (try? await session.data(from: url)) != nil
        await server.waitForConnectionsToEnd()
        return (succeeded, server.received)
    }

    @Test("A refused chain sends no request bytes")
    func aRefusedChainSendsNothing() async throws {
        let result = try await fetch(pinning: F.unknownSPKI)
        #expect(!result.succeeded)
        #expect(result.received.isEmpty)
    }

    @Test("A pinned chain sends the request, so the server would have seen one")
    func aPinnedChainSendsTheRequest() async throws {
        let result = try await fetch(pinning: try #require(TLSSPKI.sha256Base64(of: F.testRoot)))
        #expect(result.succeeded)
        #expect(String(decoding: result.received, as: UTF8.self).hasPrefix("GET / HTTP/1.1"))
    }
}

final class LocalTLSServer: @unchecked Sendable {
    struct Failed: Error {}

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalTLSServer")
    private let lock = NSLock()
    private var bytes = Data()
    private var open = 0
    private var opened = 0

    var received: Data { lock.withLock { bytes } }

    init() throws {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "tigerduck"] as CFDictionary
        guard SecPKCS12Import(TLSPinFixtures.testLeafPKCS12 as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String],
              let identity = sec_identity_create(raw as! SecIdentity) else { throw Failed() }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        listener = try NWListener(using: NWParameters(tls: tls), on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    }

    func start() async throws -> UInt16 {
        let resumed = LockedFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    if resumed.setOnce() { continuation.resume() }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        guard let port = listener.port?.rawValue else { throw Failed() }
        return port
    }

    func stop() {
        listener.cancel()
    }

    /// Returns once every accepted connection has closed, or after five seconds.
    func waitForConnectionsToEnd() async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if lock.withLock({ opened > 0 && open == 0 }) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func serve(_ connection: NWConnection) {
        lock.withLock {
            open += 1
            opened += 1
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.lock.withLock { self?.open -= 1 }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let request = lock.withLock {
                    self.bytes.append(data)
                    return self.bytes
                }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive(on: connection)
        }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func setOnce() -> Bool {
        lock.withLock {
            defer { set = true }
            return !set
        }
    }
}
#endif
