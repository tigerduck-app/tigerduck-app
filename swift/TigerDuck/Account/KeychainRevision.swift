/// The Keychain cannot be observed, so an `@Observable` owner keeps one of these, moves it on at
/// each change it makes or learns of, and reads the Keychain through `read(_:)`.
struct KeychainRevision {
    private var count = 0

    mutating func moveOn() {
        count &+= 1
    }

    func read<Value>(_ keychain: () -> Value) -> Value {
        keychain()
    }
}
