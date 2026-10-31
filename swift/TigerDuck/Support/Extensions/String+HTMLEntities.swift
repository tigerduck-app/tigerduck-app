import Foundation

extension String {
    func decodingHTMLEntities() -> String {
        guard contains("&") else { return self }

        var result = ""
        result.reserveCapacity(count)
        var index = startIndex

        while index < endIndex {
            if self[index] == "&",
               let semicolon = nextSemicolon(after: index),
               let decoded = Self.decodeEntity(self[self.index(after: index)..<semicolon]) {
                result.append(decoded)
                index = self.index(after: semicolon)
            } else {
                result.append(self[index])
                index = self.index(after: index)
            }
        }
        return result
    }

    private func nextSemicolon(after start: Index) -> Index? {
        let maxBodyLength = 10
        let bodyStart = self.index(after: start)
        let scanEnd = self.index(bodyStart, offsetBy: maxBodyLength, limitedBy: endIndex) ?? endIndex
        return self[bodyStart..<scanEnd].firstIndex(of: ";")
    }

    private static func decodeEntity(_ body: Substring) -> String? {
        guard !body.isEmpty else { return nil }
        if body.first == "#" {
            return decodeNumericEntity(body.dropFirst())
        }
        return namedEntities[String(body)]
    }

    private static func decodeNumericEntity(_ digits: Substring) -> String? {
        guard !digits.isEmpty else { return nil }
        let value: UInt32?
        if let first = digits.first, first == "x" || first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let codePoint = value, let scalar = Unicode.Scalar(codePoint) else {
            return nil
        }
        return String(Character(scalar))
    }

    private static let namedEntities: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": "\u{00A0}",
        "copy": "©",
        "reg": "®",
        "trade": "™",
        "hellip": "…",
        "mdash": "—",
        "ndash": "–",
        "lsquo": "\u{2018}",
        "rsquo": "\u{2019}",
        "sbquo": "\u{201A}",
        "ldquo": "\u{201C}",
        "rdquo": "\u{201D}",
        "bdquo": "\u{201E}",
        "laquo": "«",
        "raquo": "»",
        "bull": "•",
        "middot": "·",
        "deg": "°",
        "plusmn": "±",
        "times": "×",
        "divide": "÷",
        "frac12": "½",
        "frac14": "¼",
        "frac34": "¾",
        "sup2": "²",
        "sup3": "³",
        "para": "¶",
        "sect": "§",
        "iexcl": "¡",
        "iquest": "¿",
        "Auml": "Ä", "auml": "ä",
        "Ouml": "Ö", "ouml": "ö",
        "Uuml": "Ü", "uuml": "ü",
        "szlig": "ß",
        "Eacute": "É", "eacute": "é",
        "Egrave": "È", "egrave": "è",
        "Aacute": "Á", "aacute": "á",
        "Agrave": "À", "agrave": "à",
        "Iacute": "Í", "iacute": "í",
        "Oacute": "Ó", "oacute": "ó",
        "Uacute": "Ú", "uacute": "ú",
        "ntilde": "ñ", "Ntilde": "Ñ",
    ]
}
