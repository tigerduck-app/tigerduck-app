#if os(iOS)
import Foundation

/// IMAP modified UTF-7 (RFC 3501 §5.1.3): `&W8RO9lCZTv1TIw-` → `寄件備份匣`, the Sent folder.
/// SwiftMail hands mailbox names back undecoded.
nonisolated enum ModifiedUTF7 {
    static func decode(_ name: String) -> String {
        var output = ""
        var index = name.startIndex
        while index < name.endIndex {
            guard name[index] == "&" else {
                output.append(name[index])
                index = name.index(after: index)
                continue
            }
            guard let dash = name[index...].firstIndex(of: "-") else {
                output += name[index...]
                break
            }
            let encoded = name[name.index(after: index)..<dash]
            if encoded.isEmpty {
                output.append("&")
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                let remainder = base64.count % 4
                if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
                if let data = Data(base64Encoded: base64),
                   let text = String(data: data, encoding: .utf16BigEndian) {
                    output += text
                } else {
                    output += name[index...dash]
                }
            }
            index = name.index(after: dash)
        }
        return output
    }
}
#endif
