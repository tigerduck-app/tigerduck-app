import Foundation

enum MoodleWebserviceError: Error, Equatable, LocalizedError {
    case invalidToken
    case accessDenied
    case invalidCredentials
    case missingStoredCredentials
    case ssoLoginRejected(reason: String?)
    case webserviceDisabled
    case siteMaintenance
    case transientNetwork(underlying: String)
    case malformedResponse(detail: String)
    case httpStatus(code: Int)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return String(localized: "error_moodle_invalid_token")
        case .invalidCredentials:
            return String(localized: "error_moodle_invalid_credentials")
        case .missingStoredCredentials:
            return String(localized: "error_moodle_missing_credentials")
        case .ssoLoginRejected(let reason):
            if let reason, !reason.isEmpty {
                return String(format: String(localized: "error_moodle_sso_rejected_with_reason"), reason)
            }
            return String(localized: "error_moodle_sso_rejected")
        case .accessDenied, .webserviceDisabled:
            return String(localized: "error_moodle_webservice_disabled")
        case .siteMaintenance:
            return String(localized: "error_moodle_site_maintenance")
        case .transientNetwork(let underlying):
            return String(format: String(localized: "error_moodle_network_format"), underlying)
        case .malformedResponse(let detail):
            return String(format: String(localized: "error_moodle_malformed_response_format"), detail)
        case .httpStatus(let code):
            return String(format: String(localized: "error_moodle_http_status_format"), code)
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidToken, .missingStoredCredentials, .ssoLoginRejected:
            String(localized: "error_moodle_recovery_re_sign_in_ntust")
        case .invalidCredentials:
            String(localized: "error_moodle_recovery_check_credentials")
        case .accessDenied, .webserviceDisabled, .siteMaintenance, .transientNetwork, .malformedResponse, .httpStatus:
            nil
        }
    }

    static func from(jsonData: Data) -> MoodleWebserviceError? {
        struct MoodleErrorBody: Decodable {
            let errorcode: String?
        }

        guard let body = try? JSONDecoder().decode(MoodleErrorBody.self, from: jsonData) else {
            return nil
        }

        switch body.errorcode {
        case "invalidtoken":
            return .invalidToken
        case "accessexception":
            return .accessDenied
        case "invalidlogin":
            return .invalidCredentials
        case "enablewsdescription", "servicenotloaded":
            return .webserviceDisabled
        case "sitemaintenance":
            return .siteMaintenance
        case let code?:
            return .malformedResponse(detail: code)
        default:
            return nil
        }
    }
}
