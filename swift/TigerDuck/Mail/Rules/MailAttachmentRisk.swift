#if os(iOS)
import Foundation

/// Whether an attachment is risky to open, by its name, its declared type and the mail's text.
nonisolated enum MailAttachmentRisk {
    static let dangerousExtensions: Set<String> = [
        "apk", "apks", "xapk", "aab", "exe", "msi", "msix", "appx", "bat", "cmd", "com", "scr", "pif", "cpl",
        "vbs", "vbe", "js", "jse", "wsf", "wsh", "ps1", "psm1", "jar", "lnk", "hta", "chm", "reg", "sh",
        "command", "app", "ipa", "iso", "img", "vhd", "vhdx", "dmg", "pkg", "html", "htm", "shtml", "xhtml",
        "mht", "mhtml", "svg", "docm", "xlsm", "pptm",
    ]
    static let decoyExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "jpg", "jpeg", "png", "gif", "txt", "zip",
    ]
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz"]
    static let archivePasswordHints = ["密碼", "password", "解壓縮"]
    static let neverRenderInApp: Set<String> = ["html", "htm", "shtml", "xhtml", "mht", "mhtml", "svg"]

    static func displayFilename(_ raw: String) -> String {
        var name = MailTextCleaner.clean(raw)
        while let last = name.last, last == "." || last.isWhitespace { name.removeLast() }
        return name
    }

    private static func scannedFilename(_ raw: String) -> String {
        var name = MailTextCleaner.visibleText(MailTextCleaner.clean(raw))
        while let last = name.last, last == "." || last.isWhitespace { name.removeLast() }
        return name
    }

    static func attachmentRisk(filename: String, contentType: String?, subjectAndBody: String) -> MailRiskReason? {
        let pieces = scannedFilename(filename).lowercased().split(separator: ".").map(String.init)
        guard pieces.count >= 2, let ext = pieces.last else { return nil }
        let dangerous = dangerousExtensions.contains(ext)
        if dangerous, pieces.count >= 3, decoyExtensions.contains(pieces[pieces.count - 2]) {
            return .doubleExtension
        }
        if dangerous, let type = contentTypeWithoutParameters(contentType),
           type == "application/pdf" || type.hasPrefix("image/") || type == "text/plain" {
            return .typeMismatch
        }
        if dangerous { return .dangerousExtension }
        let lowered = MailTextCleaner.visibleText(MailTextCleaner.clean(subjectAndBody)).lowercased()
        if archiveExtensions.contains(ext), archivePasswordHints.contains(where: { lowered.contains($0) }) {
            return .encryptedArchive
        }
        return nil
    }

    static func contentTypeWithoutParameters(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.lowercased().split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func neverRenderedInApp(filename: String) -> Bool {
        let ext = scannedFilename(filename).lowercased().split(separator: ".").last.map(String.init) ?? ""
        return neverRenderInApp.contains(ext)
    }

    /// HTML/SVG, by extension or by content type, is only saved or handed to another app, never
    /// opened in Quick Look, which renders it in-process with WebKit (JavaScript on, remote loads
    /// allowed): what the locked-down message web view exists to prevent.
    static func neverRenderedInApp(filename: String, contentType: String?) -> Bool {
        if neverRenderedInApp(filename: filename) { return true }
        // Real parts carry parameters (SwiftMail appends `; charset=...`), so the type is compared
        // without them, or `text/html; charset=UTF-8` would reach Quick Look.
        let type = contentTypeWithoutParameters(contentType) ?? ""
        return type == "text/html" || type == "image/svg+xml"
    }
}
#endif
