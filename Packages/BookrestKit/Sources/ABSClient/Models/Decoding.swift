import Foundation

/// Audiobookshelf is loose with its JSON: numbers arrive as strings, optional
/// fields vanish entirely between server versions, and "minified" payloads drop
/// half the keys. These helpers let every model decode without throwing on
/// cosmetic differences, so a slightly older or newer server never blanks the UI.
extension KeyedDecodingContainer {

    /// Decodes a value that may be absent, explicitly null, or the wrong-but-adjacent type.
    func lenient<T: LosslessJSONConvertible>(_ key: Key) -> T? {
        T.decodeLeniently(from: self, forKey: key)
    }

    func lenient<T: LosslessJSONConvertible>(_ key: Key, default fallback: T) -> T {
        T.decodeLeniently(from: self, forKey: key) ?? fallback
    }

    /// Decodes an array, treating a missing key, null, or a malformed element as empty
    /// rather than failing the whole item.
    func lenientArray<T: Decodable>(_ key: Key) -> [T] {
        guard let value = try? decodeIfPresent([T].self, forKey: key) else { return [] }
        return value
    }

    func lenientValue<T: Decodable>(_ key: Key) -> T? {
        guard let value = try? decodeIfPresent(T.self, forKey: key) else { return nil }
        return value
    }
}

/// Types that can be recovered from more than one JSON representation.
public protocol LosslessJSONConvertible {
    static func decodeLeniently<K>(from container: KeyedDecodingContainer<K>, forKey key: K) -> Self?
}

extension String: LosslessJSONConvertible {
    public static func decodeLeniently<K>(from c: KeyedDecodingContainer<K>, forKey key: K) -> String? {
        if let value = try? c.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }
}

extension Double: LosslessJSONConvertible {
    public static func decodeLeniently<K>(from c: KeyedDecodingContainer<K>, forKey key: K) -> Double? {
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(String.self, forKey: key) { return Double(value) }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        return nil
    }
}

extension Int: LosslessJSONConvertible {
    public static func decodeLeniently<K>(from c: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? c.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }
}

extension Bool: LosslessJSONConvertible {
    public static func decodeLeniently<K>(from c: KeyedDecodingContainer<K>, forKey key: K) -> Bool? {
        if let value = try? c.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? c.decodeIfPresent(String.self, forKey: key) {
            return ["true", "1", "yes"].contains(value.lowercased())
        }
        return nil
    }
}

/// Audiobookshelf timestamps are milliseconds since epoch.
public enum ABSDate {
    public static func from(milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
