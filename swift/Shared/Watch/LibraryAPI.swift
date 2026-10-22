import Foundation

public struct LibraryLoginRequest: Encodable, Sendable {
    public let username: String
    public let password: String
    public let language: String

    public init(username: String, password: String, language: String = "zh") {
        self.username = username
        self.password = password
        self.language = language
    }
}

public struct LibraryLoginResponse: Decodable, Sendable {
    public let data: LibraryLoginData?
    public let error: LibraryAPIError?
}

public struct LibraryLoginData: Decodable, Sendable {
    public let username: String
    public let token: String
    public let expirationTimeStamp: Int64
}

public struct LibraryQRRequest: Encodable, Sendable {
    public let token: String
    public let language: String

    public init(token: String, language: String = "zh") {
        self.token = token
        self.language = language
    }
}

public struct LibraryQRResponse: Decodable, Sendable {
    public let data: String?
    public let error: LibraryAPIError?
}

public struct LibraryAPIError: Decodable, Sendable {
    public let code: Int
    public let message: String
}
