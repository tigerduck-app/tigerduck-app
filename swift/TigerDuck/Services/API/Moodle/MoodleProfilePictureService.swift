import Foundation

/// Sets the account's Moodle picture: the image goes into a new draft area through
/// `webservice/upload.php`, then `core_user_update_picture` makes that draft the picture.
nonisolated enum MoodleProfilePictureService {
    static let updateFunction = "core_user_update_picture"
    static let uploadPath = "/webservice/upload.php"

    static func update(
        jpeg: Data,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL,
        boundary: String = UUID().uuidString
    ) async throws {
        let draft = try await upload(jpeg: jpeg, token: token, session: session, siteURL: siteURL, boundary: boundary)
        let answer = try await MoodleWebserviceClient.call(
            updateFunction,
            params: [("draftitemid", String(draft)), ("delete", "0")],
            token: token,
            as: RawUpdate.self,
            session: session,
            siteURL: siteURL
        )
        guard answer.success else { throw MoodleWebserviceError.malformedResponse(detail: "picture not updated") }
    }

    /// The token goes in the form, not the URL, so it stays out of server logs.
    static func uploadRequest(jpeg: Data, token: String, siteURL: URL, boundary: String) -> URLRequest? {
        guard var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = uploadPath
        guard let url = components.url else { return nil }
        var body = Data()
        func part(_ headers: String, _ content: Data) {
            body.append(Data("--\(boundary)\r\n\(headers)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        part(#"Content-Disposition: form-data; name="token""#, Data(token.utf8))
        part(#"Content-Disposition: form-data; name="filearea""#, Data("draft".utf8))
        part(#"Content-Disposition: form-data; name="itemid""#, Data("0".utf8))
        part("Content-Disposition: form-data; name=\"file\"; filename=\"picture.jpg\"\r\nContent-Type: image/jpeg", jpeg)
        body.append(Data("--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func upload(jpeg: Data, token: String, session: URLSession, siteURL: URL, boundary: String) async throws -> Int {
        guard let request = uploadRequest(jpeg: jpeg, token: token, siteURL: siteURL, boundary: boundary) else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid upload URL")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: CredentialPostDelegate())
        } catch let urlError as URLError {
            throw MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
        }
        if let moodleError = MoodleWebserviceError.from(jsonData: data) { throw moodleError }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MoodleWebserviceError.httpStatus(code: status) }
        guard let draft = (try? JSONDecoder().decode([RawDraftFile].self, from: data))?.first?.itemid else {
            throw MoodleWebserviceError.malformedResponse(detail: "upload answer")
        }
        return draft
    }

    private nonisolated struct RawDraftFile: Decodable, Sendable {
        let itemid: Int
    }

    private nonisolated struct RawUpdate: Decodable, Sendable {
        let success: Bool
    }
}
