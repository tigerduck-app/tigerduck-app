import Foundation
import Testing
@testable import TigerDuck

struct MailDataImageTests {
    @Test(arguments: [
        ("data:image/png,%41%4a%4A", "AJJ"),
        ("data:image/png,A%", "A%"),
        ("data:image/png,A%4", "A%4"),
        ("data:image/png,%zz%41", "%zzA"),
        ("data:image/png,%%41", "%A"),
        ("data:image/png;base64,QUJ%2BPw%3D%3D", "AB~?"),
        ("data:image/png;charset=x;BASE64,QUI=", "AB"),
    ])
    func aPayloadDecodesAsWebKitReadsIt(source: String, expected: String) {
        #expect(MailDataImage.bytes(source) == Data(expected.utf8))
    }

    @Test func aNonASCIIByteIsKeptAsItsUTF8Bytes() {
        #expect(MailDataImage.bytes("data:image/png,é%FF") == Data([0xC3, 0xA9, 0xFF]))
    }

    @Test(arguments: ["data:image/svg+xml,<svg/>", "data:text/html,x", "data:image/pngx,AAAA", "https://x.example/p.png"])
    func aSourceThatIsNotAKeptRasterImageHasNoBytes(source: String) {
        #expect(!MailDataImage.isAllowed(source))
        #expect(MailDataImage.bytes(source) == nil)
    }
}
