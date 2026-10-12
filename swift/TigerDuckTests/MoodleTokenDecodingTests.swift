import Foundation
import Testing
@testable import TigerDuck

struct MoodleTokenDecodingTests {
    /// The bytes `moodlemobile://token=` carries: a binary signature, the wstoken and the
    /// private token, joined by `:::`. The signature bytes encode to `++++////`, so the URL-safe
    /// spelling of the triple differs from the standard one.
    private static let signatureBytes: [UInt8] = [0xFB, 0xEF, 0xBE, 0xFF, 0xFF, 0xFF]

    private static func triple(wstoken: String, privateToken: String) -> Data {
        Data(signatureBytes) + Data(":::\(wstoken):::\(privateToken)".utf8)
    }

    @Test("a standard base64 triple gives its signature, wstoken and private token")
    func standardTriple() throws {
        let encoded = Self.triple(wstoken: "ws-token", privateToken: "private-token").base64EncodedString()
        let decoded = try MoodleTokenService.decodeTokenTriple(from: encoded)
        #expect(decoded.wstoken == "ws-token")
        #expect(decoded.privatetoken == "private-token")
        #expect(decoded.signature == String(bytes: Self.signatureBytes, encoding: .isoLatin1))
    }

    @Test("the URL-safe alphabet without padding decodes to the same triple")
    func urlSafeTriple() throws {
        let standard = Self.triple(wstoken: "abc", privateToken: "xyz1").base64EncodedString()
        let urlSafe = standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(urlSafe.hasPrefix("----____"))
        #expect(standard.hasSuffix("="))

        let decoded = try MoodleTokenService.decodeTokenTriple(from: urlSafe)
        #expect(decoded.wstoken == "abc")
        #expect(decoded.privatetoken == "xyz1")
        #expect(decoded.signature == String(bytes: Self.signatureBytes, encoding: .isoLatin1))
    }

    @Test("an empty private token decodes as none")
    func emptyPrivateToken() throws {
        let encoded = Self.triple(wstoken: "ws", privateToken: "").base64EncodedString()
        #expect(try MoodleTokenService.decodeTokenTriple(from: encoded).privatetoken == nil)
    }

    @Test("anything but three parts, or no base64 at all, is a malformed response")
    func malformedTriples() {
        let malformed = [
            Data("signature:::wstoken".utf8).base64EncodedString(),
            Data("a:::b:::c:::d".utf8).base64EncodedString(),
            "!!!not base64!!!",
        ]
        for encoded in malformed {
            let error = #expect(throws: MoodleWebserviceError.self) {
                try MoodleTokenService.decodeTokenTriple(from: encoded)
            }
            guard case .malformedResponse = error else {
                Issue.record("expected a malformed response, got \(String(describing: error))")
                continue
            }
        }
    }

    @Test("Moodle error bodies map to their cases", arguments: [
        ("invalidtoken", MoodleWebserviceError.invalidToken),
        ("accessexception", .invalidToken),
        ("invalidlogin", .invalidCredentials),
        ("enablewsdescription", .webserviceDisabled),
        ("servicenotloaded", .webserviceDisabled),
        ("sitemaintenance", .malformedResponse(detail: "sitemaintenance")),
    ])
    func errorBodies(errorcode: String, expected: MoodleWebserviceError) {
        let body = #"{"exception":"moodle_exception","errorcode":"\#(errorcode)","message":"msg"}"#
        #expect(MoodleWebserviceError.from(jsonData: Data(body.utf8)) == expected)
    }

    @Test("an answer that is not a Moodle error maps to nothing")
    func nonErrorBodies() {
        let bodies = [
            #"{"courses":[{"id":1,"assignments":[]}],"warnings":[]}"#,
            #"[{"id":1,"fullname":"Course"}]"#,
            #"{"errorcode":null}"#,
            "<html><body>Service Unavailable</body></html>",
            "",
        ]
        for body in bodies {
            #expect(MoodleWebserviceError.from(jsonData: Data(body.utf8)) == nil)
        }
    }
}
