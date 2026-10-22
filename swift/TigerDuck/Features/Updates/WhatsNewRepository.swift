import Foundation

struct WhatsNewRepository {
    struct ResolvedWhatsNew: Equatable {
        let version: String
        let title: String
        let items: [Item]

        struct Item: Equatable {
            let symbol: String?
            let title: String?
            let body: String?
        }
    }

    private let bundle: Bundle
    private let resourceName: String

    nonisolated init(bundle: Bundle = .main, resourceName: String = "whatsnew") {
        self.bundle = bundle
        self.resourceName = resourceName
    }

    func entry(forVersion version: String, languageTag: String) -> ResolvedWhatsNew? {
        guard let byVersion = loadByVersion() else { return nil }
        return Self.select(
            versionEntry: byVersion[version],
            version: version,
            languageTag: languageTag
        )
    }

    func latestEntry(languageTag: String, upTo: AppVersion? = nil) -> ResolvedWhatsNew? {
        guard let byVersion = loadByVersion(), !byVersion.isEmpty else { return nil }
        let pairs = byVersion.keys.compactMap { key -> (String, AppVersion)? in
            guard let v = AppVersion(key) else { return nil }
            if let upTo, upTo < v { return nil }
            return (key, v)
        }
        let latestKey: String? = pairs
            .max(by: { $0.1 < $1.1 })?
            .0 ?? (upTo == nil ? byVersion.keys.sorted().last : nil)
        guard let latestKey else { return nil }
        return Self.select(
            versionEntry: byVersion[latestKey],
            version: latestKey,
            languageTag: languageTag
        )
    }

    private typealias ByVersion = [String: [String: WhatsNewEntry]]

    private func loadByVersion() -> ByVersion? {
        guard
            let url = bundle.url(forResource: resourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return Self.decodeByVersion(data)
    }

    static func decodeByVersion(_ data: Data) -> [String: [String: WhatsNewEntry]]? {
        try? JSONDecoder()
            .decode([String: Lenient<[String: WhatsNewEntry]>].self, from: data)
            .compactMapValues(\.value)
    }

    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    static func select(
        versionEntry: [String: WhatsNewEntry]?,
        version: String,
        languageTag: String
    ) -> ResolvedWhatsNew? {
        guard let versionEntry else { return nil }
        let entry = localeCandidates(for: languageTag)
            .lazy
            .compactMap { versionEntry[$0] }
            .first
        guard let entry,
              let title = nonBlank(entry.title)
        else {
            return nil
        }
        let items = resolvedItems(of: entry)
        guard !items.isEmpty else { return nil }
        return ResolvedWhatsNew(version: version, title: title, items: items)
    }

    private static func resolvedItems(of entry: WhatsNewEntry) -> [ResolvedWhatsNew.Item] {
        let items: [ResolvedWhatsNew.Item] = (entry.items ?? []).compactMap { item in
            let title = nonBlank(item.title)
            let body = nonBlank(item.body)
            guard title != nil || body != nil else { return nil }
            return ResolvedWhatsNew.Item(symbol: nonBlank(item.symbol), title: title, body: body)
        }
        if !items.isEmpty { return items }
        return (entry.highlights ?? []).compactMap { line in
            nonBlank(line).map { ResolvedWhatsNew.Item(symbol: nil, title: nil, body: $0) }
        }
    }

    private static func nonBlank(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func localeCandidates(for languageTag: String) -> [String] {
        guard WhatsNewLanguage.isChineseFamily(languageTag) else { return ["en"] }
        let locale = Locale(identifier: languageTag)
        let isSimplified: Bool = {
            if let script = locale.language.script?.identifier { return script == "Hans" }
            if let region = locale.region?.identifier { return region == "CN" || region == "SG" }
            return false
        }()
        return isSimplified ? ["zh-Hans", "zh-TW", "en"] : ["zh-TW", "en"]
    }
}
