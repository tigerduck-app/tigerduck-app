import Foundation

struct PortalLinkFiles: AccountScoped {
    struct Saved: Codable, Equatable {
        let links: [PortalLink]
        let fetchedAt: Date
    }

    var folders: CacheFolders = .app

    static func forgetAccount(in storage: AccountStorage) {
        storage.folders.removeCacheFiles { $0.hasPrefix("portal_links_") }
    }

    func load(studentId: String, language: PortalLanguage) -> Saved? {
        folders.cacheFiles.load(filename(studentId, language))
    }

    func save(_ saved: Saved, studentId: String, language: PortalLanguage) {
        folders.cacheFiles.save(saved, to: filename(studentId, language))
    }

    private func filename(_ studentId: String, _ language: PortalLanguage) -> String {
        "portal_links_\(language.rawValue)_\(studentId).json"
    }
}
