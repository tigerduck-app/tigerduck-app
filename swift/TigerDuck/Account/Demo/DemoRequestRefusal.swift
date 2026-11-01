import Foundation

/// Fails every request while the school sign-in is the store-review account's, before it leaves
/// the device. A session asks it first when its configuration went through
/// `refusingDemoRequests()`; `URLSession.shared` asks the classes `URLProtocol.registerClass` added.
nonisolated class DemoRequestRefusal: URLProtocol {
    class var signIns: SignInSeries { AccountSession.schoolSignIns }

    override class func canInit(with request: URLRequest) -> Bool { signIns.currentSignIn.isDemo }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

nonisolated extension URLSessionConfiguration {
    func refusingDemoRequests(with refusal: DemoRequestRefusal.Type = DemoRequestRefusal.self) -> URLSessionConfiguration {
        protocolClasses = [refusal] + (protocolClasses ?? [])
        return self
    }
}
