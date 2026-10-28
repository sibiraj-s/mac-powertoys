import Foundation

/// An opaque color in sRGB, with components from 0 to 1.
nonisolated struct PickedColor: Codable, Hashable, Identifiable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// Components outside 0…1, such as from a wide-gamut display, are clamped.
    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Through `init(red:green:blue:)`, so stored colors are clamped too.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try container.decode(Double.self, forKey: .red),
            green: try container.decode(Double.self, forKey: .green),
            blue: try container.decode(Double.self, forKey: .blue)
        )
    }

    /// Reads "#RGB" or "#RRGGBB", with or without the "#".
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Colors that look the same in HEX are the same entry in the history.
    var id: String { hex }

    var hex: String {
        String(format: "#%02X%02X%02X", red8, green8, blue8)
    }

    var red8: Int { Int((red * 255).rounded()) }
    var green8: Int { Int((green * 255).rounded()) }
    var blue8: Int { Int((blue * 255).rounded()) }

    /// Hue in degrees, then saturation and lightness from 0 to 1.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        let chroma = high - low
        let saturation = chroma == 0 ? 0 : chroma / (1 - abs(2 * lightness - 1))
        return (hue, saturation, lightness)
    }

    /// Hue in degrees, then saturation and brightness from 0 to 1.
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        return (hue, high == 0 ? 0 : (high - low) / high, high)
    }

    private var hue: Double {
        let high = max(red, green, blue), low = min(red, green, blue)
        let chroma = high - low
        guard chroma > 0 else { return 0 }
        let sector = switch high {
        case red: (green - blue) / chroma
        case green: (blue - red) / chroma + 2
        default: (red - green) / chroma + 4
        }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    func formatted(as format: ColorFormat) -> String { format.string(for: self) }

    /// Whether text on top should be dark, from the color's relative luminance.
    var isLight: Bool {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) > 0.4
    }
}

/// The ways a color can be copied.
nonisolated enum ColorFormat: String, CaseIterable, Identifiable, Sendable {
    case hex, rgb, hsl, hsb, swiftUI, nsColor, uiColor

    var id: Self { self }

    var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .hsb: "HSB"
        case .swiftUI: "SwiftUI"
        case .nsColor: "NSColor"
        case .uiColor: "UIColor"
        }
    }

    func string(for color: PickedColor) -> String {
        switch self {
        case .hex:
            return color.hex
        case .rgb:
            return "rgb(\(color.red8), \(color.green8), \(color.blue8))"
        case .hsl:
            let (hue, saturation, lightness) = color.hsl
            return "hsl(\(degrees(hue)), \(percent(saturation)), \(percent(lightness)))"
        case .hsb:
            let (hue, saturation, brightness) = color.hsb
            return "hsb(\(degrees(hue)), \(percent(saturation)), \(percent(brightness)))"
        case .swiftUI:
            return "Color(red: \(decimal(color.red)), green: \(decimal(color.green)), blue: \(decimal(color.blue)))"
        case .nsColor:
            return "NSColor(srgbRed: \(decimal(color.red)), green: \(decimal(color.green)), blue: \(decimal(color.blue)), alpha: 1)"
        case .uiColor:
            return "UIColor(red: \(decimal(color.red)), green: \(decimal(color.green)), blue: \(decimal(color.blue)), alpha: 1)"
        }
    }

    private func degrees(_ value: Double) -> String {
        String(Int(value.rounded()) % 360)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// Up to three decimals, without trailing zeros, and always with a "." whatever the locale.
    private func decimal(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
