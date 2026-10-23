import Foundation

nonisolated struct MoodleCourseMaterials: Codable, Sendable, Equatable {
    var sections: [MoodleMaterialSection]

    var count: Int {
        sections.reduce(0) { total, section in section.materials.reduce(total) { $0 + $1.count } }
    }
}

nonisolated struct MoodleMaterialSection: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let name: String
    let materials: [MoodleMaterial]
}

nonisolated struct MoodleMaterial: Codable, Sendable, Hashable, Identifiable {
    enum Content: Codable, Sendable, Hashable {
        case file(MoodleFile)
        case folder([MoodleFile])
        case link(URL)
    }

    let id: Int
    let instance: Int
    let module: String
    let name: String
    let content: Content

    var count: Int {
        switch content {
        case .file, .link: 1
        case .folder(let files): files.count
        }
    }
}

nonisolated enum MoodleCourseContentsService {
    static let contentsFunction = "core_course_get_contents"

    static func materials(
        courseId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> MoodleCourseMaterials {
        let sections = try await MoodleWebserviceClient.call(
            contentsFunction,
            params: [("courseid", String(courseId))],
            token: token,
            as: [RawSection].self,
            session: session,
            siteURL: siteURL
        )
        return MoodleCourseMaterials(sections: sections.compactMap(\.model))
    }

    static let viewCalls: [String: (function: String, parameter: String)] = [
        "resource": ("mod_resource_view_resource", "resourceid"),
        "folder": ("mod_folder_view_folder", "folderid"),
        "url": ("mod_url_view_url", "urlid"),
    ]

    static func markViewed(
        _ material: MoodleMaterial,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws {
        guard let call = viewCalls[material.module] else { return }
        _ = try await MoodleWebserviceClient.call(
            call.function,
            params: [(call.parameter, String(material.instance))],
            token: token,
            as: RawViewStatus.self,
            session: session,
            siteURL: siteURL
        )
    }
}

private nonisolated struct RawSection: Decodable, Sendable {
    let id: Int
    let name: String?
    let uservisible: Bool?
    let modules: [RawModule]?

    var model: MoodleMaterialSection? {
        guard uservisible != false else { return nil }
        let materials = (modules ?? []).compactMap(\.model)
        guard !materials.isEmpty else { return nil }
        return MoodleMaterialSection(id: id, name: MoodleHTMLText.plainText(fromHTML: name ?? ""), materials: materials)
    }
}

private nonisolated struct RawModule: Decodable, Sendable {
    let id: Int
    let name: String?
    let instance: Int?
    let modname: String
    let uservisible: Bool?
    let contents: [RawContent]?

    var model: MoodleMaterial? {
        guard uservisible != false, let instance else { return nil }
        let files = (contents ?? []).filter { $0.type == "file" }.compactMap(\.file.model)
        let content: MoodleMaterial.Content
        switch modname {
        case "resource":
            guard let file = files.first else { return nil }
            content = .file(file)
        case "folder":
            guard !files.isEmpty else { return nil }
            content = .folder(files)
        case "url":
            guard let link = contents?.first(where: { $0.type == "url" })?.file.fileurl.flatMap(URL.init(string:)),
                  ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { return nil }
            content = .link(link)
        default:
            return nil
        }
        let title = MoodleHTMLText.plainText(fromHTML: name ?? "")
        return MoodleMaterial(id: id, instance: instance, module: modname, name: title, content: content)
    }
}

private nonisolated struct RawViewStatus: Decodable, Sendable {
    let status: Bool
}

private nonisolated struct RawContent: Decodable, Sendable {
    let type: String
    let file: MoodleRawFile

    init(from decoder: any Decoder) throws {
        type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
        file = try MoodleRawFile(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}
