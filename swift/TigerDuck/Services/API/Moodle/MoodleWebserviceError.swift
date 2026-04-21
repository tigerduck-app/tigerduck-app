import Foundation

enum MoodleWebserviceError: Error, Equatable, LocalizedError {
    case invalidToken
    case invalidCredentials
    case missingStoredCredentials
    case ssoLoginRejected(reason: String?)
    case webserviceDisabled
    case transientNetwork(underlying: String)
    case malformedResponse(detail: String)
    case httpStatus(code: Int)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Moodle token 已失效，需重新授權。"
        case .invalidCredentials:
            return "Moodle 拒絕目前的登入憑證。"
        case .missingStoredCredentials:
            return "找不到已儲存的 NTUST 帳號密碼，無法重新取得 Moodle token。"
        case .ssoLoginRejected(let reason):
            if let reason, !reason.isEmpty {
                return "NTUST SSO 拒絕 Moodle 授權：\(reason)"
            }
            return "NTUST SSO 拒絕 Moodle 授權，請重新確認帳號密碼。"
        case .webserviceDisabled:
            return "Moodle webservice 目前不可用。"
        case .transientNetwork(let underlying):
            return "Moodle 網路錯誤：\(underlying)"
        case .malformedResponse(let detail):
            return "Moodle 回應格式異常：\(detail)"
        case .httpStatus(let code):
            return "Moodle HTTP 狀態碼異常：\(code)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidToken, .missingStoredCredentials, .ssoLoginRejected:
            "請重新登入 NTUST 帳號後再試一次。"
        case .invalidCredentials:
            "請確認 Moodle / NTUST 憑證是否仍有效。"
        case .webserviceDisabled, .transientNetwork, .malformedResponse, .httpStatus:
            nil
        }
    }

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
