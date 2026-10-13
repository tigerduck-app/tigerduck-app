import Foundation
import Testing

@testable import TigerDuck

/// `AppLogger.captureError` logs its line as private, but a logging profile that enables private
/// data shows it in a sysdiagnose, so anything left in it can still be read there.
@Suite("Error log scrubbing")
struct AppLoggerTests {

    @Test("a URL keeps its host and path and loses its query")
    func dropsURLQuery() {
        let line = "GET https://moodle2.ntust.edu.tw/webservice/rest/server.php?wstoken=abc123&wsfunction=core_webservice_get_site_info failed"
        #expect(
            AppLogger.scrubSensitive(line)
                == "GET https://moodle2.ntust.edu.tw/webservice/rest/server.php?*** failed"
        )
    }

    @Test("a URL without a query is left alone")
    func keepsURLWithoutQuery() {
        let url = "https://api.tigerduck.app/v3/sync/full"
        #expect(AppLogger.scrubSensitive(url) == url)
    }

    @Test("tokens, passwords and bearer values outside a query are masked", arguments: [
        ("moodlemobile://token=c2VjcmV0", "moodlemobile://token=***"),
        ("UserName=B11000000&Password=hunter2", "UserName=B11000000&Password=***"),
        ("Authorization: Bearer eyJhbGciOi.payload.sig", "Authorization: Bearer ***"),
        ("/tokenpluginfile.php/wstoken/abc123", "/tokenpluginfile.php/wstoken/***"),
        (
            "https://moodle2.ntust.edu.tw/tokenpluginfile.php/0123456789abcdef0123456789abcdef/31/mod_resource/content/2/a.pdf",
            "https://moodle2.ntust.edu.tw/tokenpluginfile.php/***/31/mod_resource/content/2/a.pdf"
        ),
    ])
    func masksCredentials(input: String, expected: String) {
        #expect(AppLogger.scrubSensitive(input) == expected)
    }

    @Test("the logged line holds the sorted context and the error, without the OIDC code")
    func errorLineIsScrubbed() {
        let error = MoodleWebserviceError.malformedResponse(
            detail: "unexpected OIDC page: https://ssoam2.ntust.edu.tw/connect/authorize/callback?client_id=moodle&code=SECRETCODE"
        )
        let line = AppLogger.errorLine(
            error,
            context: ["service": "moodleToken", "originalURL": "https://example.test/v3?token=abc"]
        )
        #expect(line.hasPrefix("originalURL=https://example.test/v3?*** service=moodleToken: "))
        #expect(line.contains("malformedResponse"))
        #expect(line.contains("https://ssoam2.ntust.edu.tw/connect/authorize/callback?***"))
        #expect(!line.contains("SECRETCODE"))
    }
}
