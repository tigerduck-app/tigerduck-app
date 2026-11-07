/// A value that decodes to nil where it cannot be read, so one bad element of a list does not
/// lose the others.
public struct Lenient<Value: Decodable>: Decodable {
    public let value: Value?

    public init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
