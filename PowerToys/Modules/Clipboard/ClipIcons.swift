import AppKit
import ImageIO
import SwiftUI

/// The small picture at the start of a row: the image itself, a color swatch, a file icon, or the
/// app it was copied from.
struct ClipIcon: View {
    let item: ClipItem
    let imageURL: URL?
    var size: CGFloat = 20

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let imageURL, let thumbnail = Thumbnails.image(at: imageURL, maxPixels: 64) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            case .color:
                let rgba = ClipItem.hexColor(item.text) ?? [0, 0, 0, 1]
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3]))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.6)))
                    .padding(2)
            case .files:
                if let first = item.fileURLs?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first.path(percentEncoded: false)))
                        .resizable()
                }
            case .text, .link:
                AppIcon(bundleID: item.sourceBundleID, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Small, cached versions of stored images, so lists don't decode full screenshots.
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL, maxPixels: Int) -> NSImage? {
        let key = "\(url.lastPathComponent)@\(maxPixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The icon of the app an item was copied from.
struct AppIcon: View {
    let bundleID: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = AppIcons.icon(for: bundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = cache[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        cache[bundleID] = icon
        return icon
    }

    static func name(for bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false)).replacing(".app", with: "")
    }
}
