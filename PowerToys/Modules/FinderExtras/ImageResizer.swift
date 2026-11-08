import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes smaller copies of images next to the originals, which are left alone.
nonisolated enum ImageResizer {
    enum Outcome: Equatable, Sendable {
        case resized(URL)
        /// Already no bigger than the size asked for.
        case alreadySmall
        case failed(String)
    }

    /// The longest sides offered, in pixels.
    static let sizes = [640, 1024, 1600, 2048, 3840]

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
    }

    /// A copy of `url` whose longest side is `longestSide` pixels, as "photo 1600px.jpg", in the
    /// same format where it can be written, otherwise PNG. Turned the way it's meant to be
    /// viewed, and without the original's metadata, such as where a photo was taken.
    static func resize(_ url: URL, longestSide: Int) -> Outcome {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return .failed("\(url.lastPathComponent) isn't an image that can be read.") }
        guard max(width, height) > longestSide else { return .alreadySmall }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failed("Couldn't resize \(url.lastPathComponent).")
        }

        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let sourceType = CGImageSourceGetType(source) as String?
        let type = sourceType.flatMap { writable.contains($0) ? UTType($0) : nil } ?? .png
        let (base, ext) = RenameRule.split(url.lastPathComponent)
        // The original's spelling, such as "JPEG", when the format stays the same.
        let newExtension = type.identifier == sourceType && !ext.isEmpty ? ext : (type.preferredFilenameExtension ?? "png")
        let destinationURL = unique(url.deletingLastPathComponent().appending(path: "\(base) \(longestSide)px.\(newExtension)"))

        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type.identifier as CFString, 1, nil)
        else { return .failed("Couldn't write a copy of \(url.lastPathComponent).") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: destinationURL)
            return .failed("Couldn't write a copy of \(url.lastPathComponent).")
        }
        return .resized(destinationURL)
    }

    /// `url`, or "name 2.ext", "name 3.ext" and so on when it's taken, as Finder numbers copies.
    static func unique(_ url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
        -> URL
    {
        guard exists(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let (base, ext) = RenameRule.split(url.lastPathComponent)
        for number in 2... {
            let candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !exists(candidate) { return candidate }
        }
        return url
    }
}
