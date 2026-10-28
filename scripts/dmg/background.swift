// Draws the DMG window's background: chevrons from PowerToys to Applications and a caption.
//
//   swift scripts/dmg/background.swift <out.png> <scale>
//
// The size and icon positions match scripts/dmg/settings.py.
import AppKit

let size = CGSize(width: 580, height: 360)
let appX: CGFloat = 160, applicationsX: CGFloat = 420, iconY: CGFloat = 150

let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[2]) else {
    FileHandle.standardError.write("usage: background.swift <out.png> <scale>\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
// Finder's coordinates start at the top left; AppKit's at the bottom left.
func flip(_ y: CGFloat) -> CGFloat { size.height - y }

/// One centred line of text whose top is `top` points from the top of the window.
func text(_ string: String, points: CGFloat, weight: NSFont.Weight, alpha: CGFloat, top: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let line = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: points, weight: weight),
        .foregroundColor: rgb(0x000000, alpha),
        .paragraphStyle: paragraph,
    ])
    let height = line.size().height
    line.draw(in: CGRect(x: 0, y: flip(top) - height, width: size.width, height: height))
}

rgb(0xFBFBFD).setFill()
CGRect(origin: .zero, size: size).fill()

// Three chevrons between the icons, fading in towards Applications.
let middle = (appX + applicationsX) / 2, y = flip(iconY)
for (i, alpha) in [0.3, 0.6, 1.0].enumerated() {
    let x = middle - 22 + CGFloat(i) * 22
    let chevron = NSBezierPath()
    chevron.move(to: CGPoint(x: x - 4, y: y + 8))
    chevron.line(to: CGPoint(x: x + 4, y: y))
    chevron.line(to: CGPoint(x: x - 4, y: y - 8))
    chevron.lineWidth = 3
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    rgb(0x0A7AFF, alpha).setStroke()
    chevron.stroke()
}

text("Drag PowerToys into the Applications folder", points: 13, weight: .regular, alpha: 0.55, top: 292)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
