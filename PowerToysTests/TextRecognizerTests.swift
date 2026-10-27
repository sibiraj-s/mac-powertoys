import AppKit
import Testing
@testable import PowerToys

struct TextRecognizerTests {
    @Test func readsTextInAnImage() async throws {
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
