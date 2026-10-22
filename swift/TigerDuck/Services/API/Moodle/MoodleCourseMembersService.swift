import Foundation

nonisolated struct MoodleMember: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let fullName: String
    let idNumber: String?
    let email: String?
    let groups: [String]
    let roles: [Role]
    let pictureURL: URL?
    let description: String
    let interests: [String]
    let fields: [Field]

    nonisolated struct Role: Codable, Sendable, Hashable {
        let shortName: String
        let name: String
        let sortOrder: Int
    }

    nonisolated struct Field: Codable, Sendable, Hashable {
        let name: String
        let value: String
    }
}

nonisolated enum MoodleCourseMembersService {
    static let membersFunction = "core_enrol_get_enrolled_users"
    static let hiddenCode = "nopermissions"

    static let userFields = "id,fullname,idnumber,email,groups,roles,profileimageurl,description,interests,customfields"

    static func members(
        courseId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [MoodleMember] {
        try await MoodleWebserviceClient.call(
            membersFunction,
            params: [
                ("courseid", String(courseId)),
                ("options[0][name]", "userfields"),
                ("options[0][value]", userFields),
            ],
            token: token,
            as: [RawMember].self,
            session: session,
            siteURL: siteURL
        ).map { $0.model(siteURL: siteURL) }
    }

    static func isOwnPicture(_ url: URL, siteURL: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == siteURL.host?.lowercased() else {
            return false
        }
        let path = url.path
        return (path.hasPrefix("/pluginfile.php/") || path.hasPrefix("/webservice/pluginfile.php/"))
            && path.contains("/user/icon/")
    }

    static func largePicture(_ url: URL) -> URL? {
        guard url.lastPathComponent == "f1",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedPath = String(components.percentEncodedPath.dropLast(2)) + "f3"
        return components.url
    }

    static func picture(
        _ url: URL,
        accessKey: String?,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> Data {
        guard isOwnPicture(url, siteURL: siteURL),
              let download = MoodleFileTransfer.downloadURL(for: url, accessKey: accessKey, token: token, siteURL: siteURL) else {
            throw MoodleWebserviceError.malformedResponse(detail: "not a member's picture")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: download)
        } catch let urlError as URLError {
            throw MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.mimeType?.hasPrefix("image/") == true else {
            throw MoodleWebserviceError.malformedResponse(detail: "not a picture")
        }
        return data
    }
}

private nonisolated struct RawMember: Decodable, Sendable {
    let id: Int
    let fullname: String
    let idnumber: String?
    let email: String?
    let groups: [RawGroup]?
    let roles: [RawRole]?
    let profileimageurl: String?
    let description: String?
    let interests: String?
    let customfields: [RawField]?

    func model(siteURL: URL) -> MoodleMember {
        let picture = profileimageurl.flatMap(URL.init(string:))
        return MoodleMember(
            id: id,
            fullName: fullname,
            idNumber: Self.nonEmpty(idnumber),
            email: Self.nonEmpty(email),
            groups: (groups ?? []).compactMap { Self.nonEmpty(MoodleHTMLText.plainText(fromHTML: $0.name)) },
            roles: (roles ?? []).map { MoodleMember.Role(shortName: $0.shortname, name: $0.name, sortOrder: $0.sortorder) },
            pictureURL: picture.flatMap { MoodleCourseMembersService.isOwnPicture($0, siteURL: siteURL) ? $0 : nil },
            description: description.map(MoodleHTMLText.plainText(fromHTML:)) ?? "",
            interests: (interests ?? "").split(separator: ",").compactMap { Self.nonEmpty(String($0)) },
            fields: (customfields ?? []).compactMap(\.model)
        )
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private nonisolated struct RawGroup: Decodable, Sendable {
    let name: String
}

private nonisolated struct RawRole: Decodable, Sendable {
    let shortname: String
    let name: String
    let sortorder: Int
}

private nonisolated struct RawField: Decodable, Sendable {
    let type: String
    let name: String
    let value: String?

    var model: MoodleMember.Field? {
        guard !["checkbox", "datetime"].contains(type),
              let label = RawMember.nonEmpty(MoodleHTMLText.plainText(fromHTML: name)),
              let text = RawMember.nonEmpty(value.map(MoodleHTMLText.plainText(fromHTML:))) else { return nil }
        return MoodleMember.Field(name: label, value: text)
    }
}
