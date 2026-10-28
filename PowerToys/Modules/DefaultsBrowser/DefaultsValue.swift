import Foundation

/// A preference value, as property lists hold them.
nonisolated enum DefaultsValue: Hashable, Sendable {
    case bool(Bool)
    case integer(Int)
    /// An integer above `Int.max`, which property lists can hold as unsigned 64-bit.
    case unsigned(UInt64)
    case real(Double)
    case string(String)
    case date(Date)
    case data(Data)
    indirect case array([DefaultsValue])
    indirect case dictionary([String: DefaultsValue])

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case bool, integer, real, string, date, data, array, dictionary

        var id: Self { self }

        var title: String {
            switch self {
            case .bool: "Boolean"
            case .integer: "Integer"
            case .real: "Number"
            case .string: "String"
            case .date: "Date"
            case .data: "Data"
            case .array: "Array"
            case .dictionary: "Dictionary"
            }
        }

        /// The kinds a value can be typed in as.
        static let editable: [Kind] = [.bool, .integer, .real, .string]
    }

    /// From what CFPreferences or PropertyListSerialization returns; nil for anything that
    /// isn't a property list value.
    init?(plist: Any) {
        switch plist {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .real(number.doubleValue)
            } else if number.compare(NSNumber(value: Int.max)) == .orderedDescending {
                self = .unsigned(number.uint64Value)
            } else {
                self = .integer(number.intValue)
            }
        case let string as String: self = .string(string)
        case let date as Date: self = .date(date)
        case let data as Data: self = .data(data)
        case let array as [Any]: self = .array(array.compactMap(DefaultsValue.init(plist:)))
        case let dictionary as [String: Any]: self = .dictionary(dictionary.compactMapValues(DefaultsValue.init(plist:)))
        default: return nil
        }
    }

    /// The value to hand CFPreferences or PropertyListSerialization.
    var plistObject: AnyObject {
        switch self {
        case .bool(let value): NSNumber(value: value)
        case .integer(let value): NSNumber(value: value)
        case .unsigned(let value): NSNumber(value: value)
        case .real(let value): NSNumber(value: value)
        case .string(let value): value as NSString
        case .date(let value): value as NSDate
        case .data(let value): value as NSData
        case .array(let values): values.map(\.plistObject) as NSArray
        case .dictionary(let values): NSDictionary(dictionary: values.mapValues(\.plistObject))
        }
    }

    var kind: Kind {
        switch self {
        case .bool: .bool
        case .integer, .unsigned: .integer
        case .real: .real
        case .string: .string
        case .date: .date
        case .data: .data
        case .array: .array
        case .dictionary: .dictionary
        }
    }

    var isEditable: Bool { Kind.editable.contains(kind) }

    /// One line describing the value, for lists.
    var summary: String {
        switch self {
        case .bool(let value): value ? "true" : "false"
        case .integer(let value): String(value)
        case .unsigned(let value): String(value)
        case .real(let value): String(value)
        case .string(let value): value
        case .date(let value): value.formatted(date: .abbreviated, time: .standard)
        case .data(let value): value.count == 1 ? "1 byte" : "\(value.count) bytes"
        case .array(let values): values.count == 1 ? "1 item" : "\(values.count) items"
        case .dictionary(let values): values.count == 1 ? "1 key" : "\(values.count) keys"
        }
    }

    /// The text an editable value is edited as.
    var editableText: String {
        switch self {
        case .string(let value): value
        default: summary
        }
    }

    /// Typed-in text as a value of `kind`; nil when it isn't one, such as "1.5" for an integer.
    static func parse(_ text: String, as kind: Kind) -> DefaultsValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .bool:
            switch trimmed.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: return nil
            }
        case .integer: return Int(trimmed).map(DefaultsValue.integer) ?? UInt64(trimmed).map(DefaultsValue.unsigned)
        case .real: return Double(trimmed).flatMap { $0.isFinite ? .real($0) : nil }
        case .string: return .string(text)
        default: return nil
        }
    }

    /// The items of an array, labelled by index, or a dictionary's entries in key order.
    var children: [(label: String, value: DefaultsValue)] {
        switch self {
        case .array(let values): values.enumerated().map { (String($0.offset), $0.element) }
        case .dictionary(let values): values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
        default: []
        }
    }

    /// Whether `text` is in the value, or in any string, number or key inside it.
    func contains(_ text: String) -> Bool {
        switch self {
        case .array, .dictionary:
            children.contains { child in
                (kind == .dictionary && child.label.localizedCaseInsensitiveContains(text)) || child.value.contains(text)
            }
        case .data, .date: false
        default: summary.localizedCaseInsensitiveContains(text)
        }
    }

    // MARK: Commands

    /// What follows the key in `defaults write`. Values with no flag of their own, such as
    /// arrays, are written as an XML property list, which `defaults` also takes.
    var commandArguments: String {
        switch self {
        case .bool(let value): "-bool \(value)"
        case .integer(let value): "-int \(value)"
        case .real(let value): "-float \(value)"
        case .string(let value): "-string \(Self.shellWord(value))"
        case .data(let value): "-data \(value.map { String(format: "%02x", $0) }.joined())"
        // Past what -int takes.
        case .unsigned, .date, .array, .dictionary: Self.shellWord(xmlFragment)
        }
    }

    /// The value as XML property list elements, without the document around them.
    var xmlFragment: String {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plistObject, format: .xml, options: 0) else { return "" }
        var xml = String(decoding: data, as: UTF8.self)
        if let start = xml.range(of: "<plist version=\"1.0\">") { xml = String(xml[start.upperBound...]) }
        if let end = xml.range(of: "</plist>", options: .backwards) { xml = String(xml[..<end.lowerBound]) }
        // Only the indentation between tags goes; text inside elements keeps its newlines.
        return xml.replacing(#/>\n\t*</#, with: "><").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func writeCommand(domain: String, key: String, value: DefaultsValue) -> String {
        "defaults write \(shellWord(domain)) \(shellWord(key)) \(value.commandArguments)"
    }

    static func readCommand(domain: String, key: String? = nil) -> String {
        (["defaults read", shellWord(domain)] + (key.map { [shellWord($0)] } ?? [])).joined(separator: " ")
    }

    static func deleteCommand(domain: String, key: String) -> String {
        "defaults delete \(shellWord(domain)) \(shellWord(key))"
    }

    /// `text` as one shell word, quoted only when it needs to be.
    static func shellWord(_ text: String) -> String {
        let plain = #/[A-Za-z0-9._\-\/:@%+=,]+/#
        return text.wholeMatch(of: plain) != nil ? text : Command.shellQuoted(text)
    }

    // MARK: Files

    /// Keys and values as a property list file. Binary, as XML keeps dates to whole seconds.
    static func plistData(_ values: [String: DefaultsValue]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: NSDictionary(dictionary: values.mapValues(\.plistObject)), format: .binary, options: 0
        )
    }

    static func values(fromPlist data: Data) throws -> [String: DefaultsValue] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dictionary.compactMapValues(DefaultsValue.init(plist:))
    }
}
