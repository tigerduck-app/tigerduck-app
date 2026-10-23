import Foundation

struct WhatsNewEntry: Decodable, Equatable {
    let title: String?
    let items: [WhatsNewItem]?
    let highlights: [String]?
}

struct WhatsNewItem: Decodable, Equatable {
    let symbol: String?
    let title: String?
    let body: String?
}
