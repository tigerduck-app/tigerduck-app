import Foundation

// MARK: - Login

struct LibraryLoginRequest: Encodable {
    let username: String
    let password: String
    let language: String = "zh"
}

struct LibraryLoginResponse: Decodable {
    let data: LibraryLoginData?
    // Optional: success responses may omit `error`. Decoding it as
    // non-optional made every successful response fail decoding.
    let error: LibraryAPIError?
}

struct LibraryLoginData: Decodable {
    let username: String
    let token: String
    let expirationTimeStamp: Int64
}

// MARK: - QR Code Generation

struct LibraryQRRequest: Encodable {
    let token: String
    let language: String = "zh"
}

struct LibraryQRResponse: Decodable {
    let data: String?
    // Optional: success responses may omit `error`. Decoding it as
    // non-optional made every successful response fail decoding.
    let error: LibraryAPIError?
}

// MARK: - Shared Error

struct LibraryAPIError: Decodable {
    let code: Int
    let message: String
}
