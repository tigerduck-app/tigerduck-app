import Defaults
import SwiftUI

/// The `Defaults` keys of an account (docs/account-state.md), declared as statics of `AccountKeys`.
/// `Defaults[.key]` reads one. A write names the `SignIn` it was read for, `Defaults[.key, for:]`,
/// and lands only while that sign-in is current; the sign-out clears a key with `Defaults.reset`.
nonisolated class AccountKeys: @unchecked Sendable {
    fileprivate let erased: Defaults.Keys

    fileprivate init(erased: Defaults.Keys) {
        self.erased = erased
    }
}

nonisolated final class AccountKey<Value: Defaults.Serializable>: AccountKeys, @unchecked Sendable {
    fileprivate let key: Defaults.Key<Value>

    init(_ name: String, default value: Value, suite: UserDefaults = .standard) {
        key = Defaults.Key(name, default: value, suite: suite)
        super.init(erased: key)
    }

    convenience init<Wrapped>(_ name: String, suite: UserDefaults = .standard) where Value == Wrapped? {
        self.init(name, default: nil, suite: suite)
    }
}

nonisolated extension Defaults {
    static subscript<Value>(key: AccountKey<Value>) -> Value {
        Defaults[key.key]
    }

    static subscript<Value>(key: AccountKey<Value>, for signIn: SignIn) -> Value {
        get { Defaults[key.key] }
        set {
            guard signIn.isCurrent else { return }
            Defaults[key.key] = newValue
        }
    }

    static func reset(_ keys: AccountKeys...) {
        for key in keys { key.erased.reset() }
    }

    static func observe<Value>(
        _ key: AccountKey<Value>, options: ObservationOptions, handler: @escaping (KeyChange<Value>) -> Void
    ) -> some Defaults.Observation {
        Defaults.observe(key.key, options: options, handler: handler)
    }
}

/// `@Default` for an account key, which a view reads and follows but cannot write.
@propertyWrapper
struct AccountDefault<Value: Defaults.Serializable>: DynamicProperty {
    @Default private var value: Value

    init(_ key: AccountKey<Value>) {
        _value = Default(key.key)
    }

    var wrappedValue: Value { value }
}
