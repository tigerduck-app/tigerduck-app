import Foundation

/// A session asks the URL protocols of its configuration, where `refusingDemoRequests()` puts this
/// one first; `URLSession.shared` asks the ones `URLProtocol.registerClass` added.
nonisolated class DemoRequestRefusal: URLProtocol {
    class var signIns: SignInSeries { AccountSession.schoolSignIns }

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme?.lowercased()) && signIns.currentSignIn.isDemo
    }

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
