import Foundation

/// A course's materials as its Moodle page lists them: the sections in Moodle's order, each with
/// its files, folders and links. Other activities have screens of their own or open in Moodle.
nonisolated struct MoodleCourseMaterials: Codable, Sendable, Equatable {
    var sections: [MoodleMaterialSection]

    /// What the course detail counts: files and links, a folder by the files in it.
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

    /// The course module, which Moodle's pages take as `id`.
    let id: Int
    /// The resource, folder or URL the module shows, which its view call takes.
    let instance: Int
    /// Moodle's name for the kind of module: `resource`, `folder` or `url`.
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

/// `core_course_get_contents`, which lists a course's sections and the modules in each. The call
/// takes the token, so the caller runs it inside `MoodleWebserviceClient.withToken`.
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

    /// The call that logs a view of each kind of module, with the name it takes the instance by.
    static let viewCalls: [String: (function: String, parameter: String)] = [
        "resource": ("mod_resource_view_resource", "resourceid"),
        "folder": ("mod_folder_view_folder", "folderid"),
        "url": ("mod_url_view_url", "urlid"),
    ]

    /// Logs a view of `material` on Moodle, which may count toward the activity's completion.
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

// MARK: - Answers

private nonisolated struct RawSection: Decodable, Sendable {
    let id: Int
    let name: String?
    let uservisible: Bool?
    let modules: [RawModule]?

    /// Nil for a section the account cannot open or with nothing to show.
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

    /// A file, folder or link the account can open, else nil. A resource shows its first file,
    /// which Moodle lists as the main one; a link only an http or https address.
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
