import Foundation

/// Renders probe values so a missing key is visible.
public enum ProbeFormat {
    /// Music omits integer keys whose value is zero, so a missing key tells us something.
    /// Nil renders differently from empty.
    public static func value(_ value: Any?) -> String {
        switch value {
        case .none: "‹absent›"
        case let string as String: string.isEmpty ? "‹empty string›" : string
        case let number as NSNumber: number.stringValue
        case let date as Date: date.formatted(.iso8601)
        case let some?: String(describing: some)
        }
    }

    /// Reduces a notification payload to `Sendable` strings.
    ///
    /// Call it synchronously on the thread that delivered the notification, before handing
    /// anything to another isolation domain: `[AnyHashable: Any]` isn't `Sendable`.
    public static func flatten(_ dictionary: [AnyHashable: Any]) -> [String: String] {
        var flattened: [String: String] = [:]
        for (key, rawValue) in dictionary {
            guard let key = key as? String else { continue }
            flattened[key] = value(rawValue)
        }
        return flattened
    }

    /// Renders a flattened payload with a stable key order, marking which of the expected
    /// keys were absent.
    public static func dictionary(
        _ dictionary: [String: String],
        expectedKeys: [String]
    ) -> [(key: String, value: String)] {
        var fields: [(key: String, value: String)] = []
        for key in expectedKeys {
            // Absent isn't the same as empty: Music omits integer keys valued zero.
            fields.append((key, dictionary[key] ?? "‹absent›"))
        }
        // Keys we didn't expect, marked with ＋.
        let known = Set(expectedKeys)
        for key in dictionary.keys.filter({ !known.contains($0) }).sorted() {
            fields.append(("＋\(key)", dictionary[key] ?? "‹absent›"))
        }
        return fields
    }

    /// JSON-encodes a `Codable` value so opaque types can be inspected.
    ///
    /// The probe reads `PlayParameters` this way. It's `Codable` but has no public members,
    /// and its payload may carry `kind: "radioStation"` for stations.
    public static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return "‹not encodable›" }
        return string
    }
}
