import Foundation

/// Request/response DTOs for `/v2/bulletins` and related subscription
/// routes. Mirrors `backend/server/bulletins/schemas.py`. Keep both sides
/// in sync when evolving the API contract.
///
/// Taxonomy values (`CanonicalOrg`, `ContentTag`) are decoded as plain
/// strings so a newly-introduced server enum does not hard-fail the whole
/// payload — iOS falls back to showing the raw id label until the client
/// binary catches up.
enum BulletinAPI {
    // MARK: - Taxonomy

    struct OrgLabel: Codable, Sendable, Hashable, Identifiable {
        var id: String { rawId }
        let rawId: String
        let label: String

        enum CodingKeys: String, CodingKey {
            case rawId = "id"
            case label
        }
    }

    struct TagLabel: Codable, Sendable, Hashable, Identifiable {
        var id: String { rawId }
        let rawId: String
        let label: String

        enum CodingKeys: String, CodingKey {
            case rawId = "id"
            case label
        }
    }

    struct TaxonomyResponse: Codable, Sendable {
        let orgs: [OrgLabel]
        let tags: [TagLabel]
        let defaultTags: [String]

        enum CodingKeys: String, CodingKey {
            case orgs
            case tags
            case defaultTags = "default_tags"
        }
    }

    // MARK: - Bulletins

    enum Importance: String, Codable, Sendable, CaseIterable {
        case low
        case normal
        case high
    }

    struct BulletinSummary: Codable, Sendable, Identifiable, Hashable {
        let id: Int
        let externalId: String
        let title: String
        /// LLM-normalized title (≤24 全形 chars, no decorative prefixes,
        /// no publisher prefix). `nil` for legacy rows that have not yet
        /// been re-classified — fall back to `title`.
        let titleClean: String?
        let canonicalOrg: String?
        let contentTags: [String]
        let importance: Importance?
        let summary: String?
        let sourceUrl: String
        let postedAt: Date?
        let isDeleted: Bool

        /// What the UI should display as the bulletin headline.
        var displayTitle: String { titleClean ?? title }

        enum CodingKeys: String, CodingKey {
            case id
            case externalId = "external_id"
            case title
            case titleClean = "title_clean"
            case canonicalOrg = "canonical_org"
            case contentTags = "content_tags"
            case importance
            case summary
            case sourceUrl = "source_url"
            case postedAt = "posted_at"
            case isDeleted = "is_deleted"
        }
    }

    struct BulletinDetail: Codable, Sendable, Identifiable, Hashable {
        let id: Int
        let externalId: String
        let title: String
        let titleClean: String?
        let canonicalOrg: String?
        let contentTags: [String]
        let importance: Importance?
        let summary: String?
        let sourceUrl: String
        let postedAt: Date?
        let isDeleted: Bool
        let bodyClean: String?
        let bodyMd: String?
        let rawPublisher: String?

        var displayTitle: String { titleClean ?? title }

        enum CodingKeys: String, CodingKey {
            case id
            case externalId = "external_id"
            case title
            case titleClean = "title_clean"
            case canonicalOrg = "canonical_org"
            case contentTags = "content_tags"
            case importance
            case summary
            case sourceUrl = "source_url"
            case postedAt = "posted_at"
            case isDeleted = "is_deleted"
            case bodyClean = "body_clean"
            case bodyMd = "body_md"
            case rawPublisher = "raw_publisher"
        }
    }

    struct BulletinListResponse: Codable, Sendable {
        let items: [BulletinSummary]
        let nextCursor: Int?

        enum CodingKeys: String, CodingKey {
            case items
            case nextCursor = "next_cursor"
        }
    }

    // MARK: - Subscriptions

    enum SubscriptionMode: String, Codable, Sendable, CaseIterable, Identifiable {
        case and = "AND"
        case or = "OR"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .and: return String(localized: "bulletin_subscription_mode_and")
            case .or: return String(localized: "bulletin_subscription_mode_or")
            }
        }
    }

    struct SubscriptionRule: Codable, Sendable, Identifiable, Hashable {
        /// Server-assigned numeric id. `nil` for newly-authored rules that
        /// have never been PUT.
        let id: Int?
        /// Stable client-side identity so SwiftUI `ForEach` / diffing keeps
        /// working across edits on rules that have not yet been saved.
        var clientId: UUID = .init()
        var name: String?
        var orgs: [String]
        var tags: [String]
        var mode: SubscriptionMode
        var enabled: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case orgs
            case tags
            case mode
            case enabled
        }

        init(
            id: Int? = nil,
            clientId: UUID = .init(),
            name: String? = nil,
            orgs: [String] = [],
            tags: [String] = [],
            mode: SubscriptionMode = .and,
            enabled: Bool = true
        ) {
            self.id = id
            self.clientId = clientId
            self.name = name
            self.orgs = orgs
            self.tags = tags
            self.mode = mode
            self.enabled = enabled
        }
    }

    struct SubscriptionsPutRequest: Codable, Sendable {
        let rules: [SubscriptionRule]
    }

    struct SubscriptionsResponse: Codable, Sendable {
        /// `nil` on v3 responses where the server no longer echoes device_id.
        let deviceId: String?
        let rules: [SubscriptionRule]

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case rules
        }
    }
}
