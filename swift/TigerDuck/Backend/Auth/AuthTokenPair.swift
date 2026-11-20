import Foundation

extension AuthTokenManager {
    nonisolated struct TokenStore: Sendable {
        let load: @Sendable (_ key: String) -> String?
        let save: @Sendable (_ key: String, _ value: String) -> Void
        let delete: @Sendable (_ key: String) -> Void
        var confirmedSave: (@Sendable (_ key: String, _ value: String) -> Bool)?
        var confirmedDelete: (@Sendable (_ key: String) -> Bool)?

        static let keychain = TokenStore(
            load: { KeychainManager.loadString(key: $0) },
            save: { KeychainManager.saveString(key: $0, value: $1) },
            delete: { KeychainManager.delete(key: $0) },
            confirmedSave: { KeychainManager.saveStringReportingSuccess(key: $0, value: $1) },
            confirmedDelete: { KeychainManager.deleteReportingSuccess(key: $0) }
        )

        func saveConfirmed(_ key: String, _ value: String) -> Bool {
            if let confirmedSave { return confirmedSave(key, value) }
            save(key, value)
            return true
        }

        func deleteConfirmed(_ key: String) -> Bool {
            if let confirmedDelete { return confirmedDelete(key) }
            delete(key)
            return true
        }
    }
}

nonisolated struct AuthTokenPair {
    let tokens: AuthTokenManager.TokenStore
    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    var expiresAt: Date = .distantPast
    var budget = UnconfirmedRefreshSends()
    private(set) var refreshTokenIsStored = true
    private(set) var signIn: SignIn?

    init(tokens: AuthTokenManager.TokenStore, signIn: SignIn) {
        self.tokens = tokens
        self.signIn = signIn
        accessToken = tokens.load(AuthTokenManager.accessTokenKey)
        refreshToken = tokens.load(AuthTokenManager.refreshTokenKey)
        if let raw = tokens.load(AuthTokenManager.expiresAtKey),
           let interval = TimeInterval(raw) {
            expiresAt = Date(timeIntervalSince1970: interval)
        }
        budget = UnconfirmedRefreshSends(stored: tokens.load(AuthTokenManager.refreshTokenUsesKey))
    }

    func holds(_ signIn: SignIn) -> Bool {
        signIn.isCurrent && self.signIn == signIn
    }

    mutating func store(access: String, refresh: String, expiresIn: Int, for signIn: SignIn) {
        self.signIn = signIn
        accessToken = access
        refreshToken = refresh
        budget = UnconfirmedRefreshSends()
        expiresAt = Date.now.addingTimeInterval(TimeInterval(expiresIn))
        tokens.save(AuthTokenManager.accessTokenKey, access)
        tokens.save(AuthTokenManager.expiresAtKey, String(expiresAt.timeIntervalSince1970))
        refreshTokenIsStored = tokens.saveConfirmed(AuthTokenManager.refreshTokenKey, refresh)
        if refreshTokenIsStored { tokens.delete(AuthTokenManager.refreshTokenUsesKey) }
    }

    mutating func clear() {
        signIn = nil
        accessToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        tokens.delete(AuthTokenManager.accessTokenKey)
        tokens.delete(AuthTokenManager.expiresAtKey)
        if tokens.deleteConfirmed(AuthTokenManager.refreshTokenKey) { tokens.delete(AuthTokenManager.refreshTokenUsesKey) }
    }

    mutating func saveBudget(_ budget: UnconfirmedRefreshSends, of token: String) -> Bool {
        guard refreshToken == token, ensureRefreshTokenStored() else { return false }
        return tokens.saveConfirmed(AuthTokenManager.refreshTokenUsesKey, budget.stored)
    }

    private mutating func ensureRefreshTokenStored() -> Bool {
        if !refreshTokenIsStored, let refreshToken {
            refreshTokenIsStored = tokens.saveConfirmed(AuthTokenManager.refreshTokenKey, refreshToken)
        }
        return refreshTokenIsStored
    }
}
