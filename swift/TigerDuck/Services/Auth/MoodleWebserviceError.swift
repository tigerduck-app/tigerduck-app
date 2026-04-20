import Foundation

enum MoodleWebserviceError: Error, Equatable {
    case invalidToken
    case invalidCredentials
    case webserviceDisabled
    case transientNetwork(underlying: String)
    case malformedResponse(detail: String)
    case httpStatus(code: Int)

    /// Parse a Moodle error response body into the appropriate error case.
    /// Returns nil if the data does not contain a recognizable Moodle error.
    static func from(jsonData: Data) -> MoodleWebserviceError? {
        struct MoodleErrorBody: Decodable {
            let errorcode: String?
        }

        guard let body = try? JSONDecoder().decode(MoodleErrorBody.self, from: jsonData) else {
            return nil
        }

        switch body.errorcode {
        case "invalidtoken", "accessexception":
            return .invalidToken
        case "invalidlogin":
            return .invalidCredentials
        case "enablewsdescription", "servicenotloaded":
            return .webserviceDisabled
        case let code?:
            return .malformedResponse(detail: code)
        default:
            return nil
        }
    }
}
