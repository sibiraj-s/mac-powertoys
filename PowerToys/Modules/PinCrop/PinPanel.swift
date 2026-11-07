import AppKit
import ScreenCaptureKit

/// A pin on screen; a protocol so tests don't show one.
protocol PinWindow: AnyObject {
    /// Where the pin is, in top-left global coordinates.
    var frame: CGRect { get }
    /// Hidden while the real window is in front in its place.
    func setHidden(_ hidden: Bool)
    func close()
}

/// Puts a live copy of a window, or part of one, in a floating panel; a protocol so tests don't capture the screen.
protocol PinPresenting {
    /// The pin, or nil when the window can't be captured, as when it closed while picking.
    /// `onClose` runs when the pin closes on its own: closed from its panel, or its window closed.
    func present(_ selection: WindowSelection, onShowSource: @escaping () -> Void, onClose: @escaping () -> Void) async -> (any PinWindow)?
}

struct LivePinPresenter: PinPresenting {
    func present(_ selection: WindowSelection, onShowSource: @escaping () -> Void, onClose: @escaping () -> Void) async -> (any PinWindow)?
    {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
            let window = content.windows.first(where: { $0.windowID == selection.window.id })
        else { return nil }
        let pin = LivePin(selection: selection, onShowSource: onShowSource, onClose: onClose)
        return await pin.start(capturing: window) ? pin : nil
    }
}

/// Streams the window into a panel that floats above other windows, on every Space.
private final class LivePin: NSObject, PinWindow, SCStreamOutput, SCStreamDelegate {
    private let selection: WindowSelection
    private let onClose: () -> Void
    private let panel: PinPanel
    private var stream: SCStream?
    private var isClosed = false

    init(selection: WindowSelection, onShowSource: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.selection = selection
        self.onClose = onClose
        panel = PinPanel(frame: Displays.flip(selection.sourceRect), appName: selection.window.appName)
        super.init()
        panel.pinView.onShowSource = onShowSource
        panel.pinView.onClose = { [weak self] in self?.finish(notifying: true) }
    }

    func start(capturing window: SCWindow) async -> Bool {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let size = selection.crop?.size ?? selection.window.frame.size
        let configuration = SCStreamConfiguration()
        if let crop = selection.crop { configuration.sourceRect = crop }
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.queueDepth = 4

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            // Frames arrive on the main queue: there are few pins, and the panel's layer is updated there.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
        } catch {
            NSLog("Pin capture failed: \(error)")
            return false
        }
        self.stream = stream
        panel.orderFrontRegardless()
        return true
    }

    var frame: CGRect { Displays.flip(panel.frame) }

    func setHidden(_ hidden: Bool) {
        guard !isClosed else { return }
        hidden ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    func close() {
        finish(notifying: false)
    }

    private func finish(notifying: Bool) {
        guard !isClosed else { return }
        isClosed = true
        panel.orderOut(nil)
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        if notifying { onClose() }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only complete frames carry an image; idle ones, sent while nothing changes, don't.
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer,
            let image = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        // Delivered on the main queue (see `start`), so the surface never leaves it.
        nonisolated(unsafe) let surface = image
        MainActor.assumeIsolated {
            panel.pinView.layer?.contents = surface
        }
    }

    /// Stops when the window closes or its app quits.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in self.finish(notifying: true) }
    }
}

private final class PinPanel: NSPanel {
    let pinView: PinView

    init(frame: CGRect, appName: String) {
        pinView = PinView(appName: appName)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        // Panels hide when their app stops being active by default; a pin stays up whatever is in front.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        // Resizing keeps the window's proportions, so the copy is never stretched or letterboxed.
        contentAspectRatio = frame.size
        minSize = CGSize(width: 60, height: 40)
        contentView = pinView
    }
}

private final class PinView: NSView {
    var onShowSource: (() -> Void)?
    var onClose: (() -> Void)?
    private let appName: String
    private let closeButton: NSButton

    init(appName: String) {
        self.appName = appName
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close pin")!, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        closeButton.isBordered = false
        closeButton.symbolConfiguration = .init(pointSize: 16, weight: .regular).applying(
            .init(paletteColors: [.white, .black.withAlphaComponent(0.6)]))
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "Close"
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
        ])
        toolTip = "Double-click to use the window here. Drag to move, drag an edge to resize."
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onShowSource?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Use Window Here", action: #selector(showSource), keyEquivalent: "").target = self
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacities = NSMenu()
        for percent in [100, 80, 60, 40] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = Int(((window?.alphaValue ?? 1) * 100).rounded()) == percent ? .on : .off
            opacities.addItem(item)
        }
        opacity.submenu = opacities
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(close), keyEquivalent: "").target = self
        return menu
    }

    @objc private func showSource() { onShowSource?() }
    @objc private func close() { onClose?() }
    @objc private func setOpacity(_ item: NSMenuItem) { window?.alphaValue = CGFloat(item.tag) / 100 }
}
