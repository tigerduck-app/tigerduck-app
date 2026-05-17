import Foundation

nonisolated extension Data {
    /// Lowercase hex encoding. Used for APNs/PTS token hex strings sent to the
    /// push server.
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
