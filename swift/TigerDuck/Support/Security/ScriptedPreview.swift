import Foundation

/// Quick Look renders HTML and SVG in the app with scripts on.
nonisolated enum ScriptedPreview {
    static let extensions: Set<String> = ["html", "htm", "shtml", "xhtml", "mht", "mhtml", "svg"]

    static func isScripted(extension ext: String, contentType: String?) -> Bool {
        if extensions.contains(ext.lowercased()) { return true }
        let type = contentType?.lowercased().split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return type == "text/html" || type == "image/svg+xml"
    }
}
