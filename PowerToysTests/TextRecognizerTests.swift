import AppKit
import Testing
import Vision
@testable import PowerToys

/// Vision reads no text on some Macs, such as CI's virtual ones, though it runs without an
/// error. Tests that read text skip themselves there. The check asks Vision directly, so a
/// fault in our own reading still fails them.
enum TextRecognition {
    static func requireAvailable() async throws {
        guard await isAvailable.value else {
            try Test.cancel("Vision recognizes no text on this Mac")
        }
    }

    private static let isAvailable = Task { @MainActor in
        let image = NSImage(size: NSSize(width: 300, height: 100), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Hello" as NSString).draw(at: NSPoint(x: 20, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 48)])
            return true
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let observations = try? await RecognizeTextRequest().perform(on: cgImage) else { return false }
        return !observations.isEmpty
    }
}

struct TextRecognizerTests {
    @Test func readsTextInAnImage() async throws {
        try await TextRecognition.requireAvailable()
        let image = NSImage(size: NSSize(width: 600, height: 120), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Hello Clipboard" as NSString).draw(
                at: NSPoint(x: 20, y: 30),
                withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
            )
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = URL.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await TextRecognizer.text(in: url) == "Hello Clipboard")
    }

    @Test func blankImageHasNoText() async throws {
        let url = URL.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString).png")
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 50, pixelsHigh: 50, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await TextRecognizer.text(in: url).isEmpty)
    }
}
