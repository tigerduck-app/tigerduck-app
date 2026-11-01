#if os(iOS)
import Foundation

nonisolated enum DemoMailMIME {
    static func textBody(of message: Data) -> String {
        guard let firstBlank = message.range(of: Data("\r\n\r\n".utf8)) else { return "" }
        let headerText = String(decoding: message[message.startIndex..<firstBlank.lowerBound], as: UTF8.self)
        let rest = message[firstBlank.upperBound...]

        guard headerText.range(of: "multipart/", options: .caseInsensitive) != nil else {
            var body = rest
            if body.suffix(2).elementsEqual(Data("\r\n".utf8)) { body = body.dropLast(2) }
            return decodedBody(Data(body), encoding: headerValue(named: "Content-Transfer-Encoding", in: headerText))
        }

        guard let boundaryLineEnd = rest.range(of: Data("\r\n".utf8)) else { return "" }
        let afterBoundary = rest[boundaryLineEnd.upperBound...]
        guard let partBlank = afterBoundary.range(of: Data("\r\n\r\n".utf8)) else { return "" }
        let partHeaderText = String(decoding: afterBoundary[afterBoundary.startIndex..<partBlank.lowerBound], as: UTF8.self)
        var body = afterBoundary[partBlank.upperBound...]
        if let closing = body.range(of: Data("\r\n--".utf8)) {
            body = body[body.startIndex..<closing.lowerBound]
        }
        return decodedBody(Data(body), encoding: headerValue(named: "Content-Transfer-Encoding", in: partHeaderText))
    }

    private static func headerValue(named name: String, in headerBlock: String) -> String? {
        MailRawHeaders.value(named: name, in: Data((headerBlock + "\r\n\r\n").utf8))
    }

    private static func decodedBody(_ body: Data, encoding: String?) -> String {
        switch encoding?.lowercased() {
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        case "base64":
            let compact = Data(body.filter { $0 != 0x0D && $0 != 0x0A })
            guard let decoded = Data(base64Encoded: compact) else { return String(decoding: body, as: UTF8.self) }
            return String(decoding: decoded, as: UTF8.self)
        default:
            return String(decoding: body, as: UTF8.self)
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> String {
        var output = [UInt8]()
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D {
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                    output.append(UInt8(high * 16 + low))
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x46: return Int(byte - 0x41) + 10
        case 0x61...0x66: return Int(byte - 0x61) + 10
        default: return nil
        }
    }
}
#endif
