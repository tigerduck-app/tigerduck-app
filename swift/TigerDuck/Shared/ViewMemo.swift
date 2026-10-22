import Foundation

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
