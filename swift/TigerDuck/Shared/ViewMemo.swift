import Foundation

/// Keeps a view's derived value for one key, held in `@State` and read through a computed
/// property, so data every cell reads is built once per change instead of once per cell.
/// Mutating it inside `body` is no state change, as SwiftUI does not observe a plain class.
final class ViewMemo<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?

    func value(for key: Key, build: () -> Value) -> Value {
        if let value, self.key == key { return value }
        let built = build()
        self.key = key
        value = built
        return built
    }
}
