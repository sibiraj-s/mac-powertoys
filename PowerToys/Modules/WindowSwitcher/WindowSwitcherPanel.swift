import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The switcher on the display with the pointer, and the peek dimming every display around the
/// selected window. It takes keys without activating PowerToys, and watches the modifier keys to
/// switch once they're let go of.
final class WindowSwitcherPanel: SwitcherPresenting {
    private weak var controller: WindowSwitcherController?
    private var panel: SwitcherKeyPanel?
    private var peekPanels: [NSPanel] = []
    private var columns = 1
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// Counts showings, so a fade-out that ends after the switcher opened again leaves it up.
    private var showing = 0

    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(_ controller: WindowSwitcherController) {
        self.controller = controller
        let panel = panel ?? makePanel()
        self.panel = panel
        showing += 1

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let size: CGSize
        switch controller.style {
        case .grid:
            let grid = SwitcherLayout.grid(count: controller.windows.count, in: area.size)
            columns = grid.columns
            size = grid.size
            panel.contentView = NSHostingView(rootView: SwitcherGridView(controller: controller, columns: grid.columns))
        case .stack:
            columns = 1
            let stack = SwitcherLayout.stack(in: area.size)
            size = stack.size
            panel.contentView = NSHostingView(rootView: SwitcherStackView(controller: controller, stack: stack))
        }
        let origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        panel.ignoresMouseEvents = false

        for peek in peekPanels { peek.orderOut(nil) }
        peekPanels = controller.showsPeek ? NSScreen.screens.map { makePeekPanel(on: $0, controller: controller) } : []
        let panels = peekPanels + [panel]
        let fades = !Self.reducesMotion
        for window in panels { window.alphaValue = fades ? 0 : 1 }
        for peek in peekPanels { peek.orderFrontRegardless() }
        panel.makeKeyAndOrderFront(nil)
        if fades {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for window in panels { window.animator().alphaValue = 1 }
            }
        }

        guard monitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged],
            handler: { [weak self] event in
                // Local monitors run on the main thread. Only a Bool crosses back, since NSEvent isn't Sendable.
                let isHandled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return isHandled ? nil : event
            })
        {
            monitors.append(local)
        }
        // A click in another app closes the switcher, even while an action has it ignoring lost keys.
        if let clicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.controller?.cancel() }
            })
        {
            monitors.append(clicks)
        }
        // Modifiers let go of while another app has the keys, before the panel became key.
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged,
            handler: { [weak self] event in
                let flags = event.modifierFlags
                MainActor.assumeIsolated { self?.controller?.modifiersChanged(flags) }
            })
        {
            monitors.append(global)
        }
    }

    func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard let panel, panel.isVisible else { return }
        let peeks = peekPanels
        peekPanels = []
        guard !Self.reducesMotion else {
            panel.orderOut(nil)
            panel.contentView = nil
            for peek in peeks { peek.orderOut(nil) }
            return
        }
        // Fades while the chosen window comes forward behind it; clicks go through meanwhile.
        let fading = showing
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in peeks + [panel] { window.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                for peek in peeks { peek.orderOut(nil) }
                guard let self, self.showing == fading else { return }
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }
    }

    func refocus() {
        guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
        panel.makeKey()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let controller, event.window === panel else { return false }
        if event.type == .flagsChanged {
            controller.modifiersChanged(event.modifierFlags)
            return false
        }
        // The shortcut's own key with its modifiers steps on through the hot key; with ⇧ added it gets here.
        if Int(event.keyCode) == controller.stepKeyCode {
            controller.step(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        }
        switch Int(event.keyCode) {
        case kVK_Escape: controller.cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: controller.commit()
        case kVK_Tab: controller.step(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        case kVK_LeftArrow: controller.step(by: -1)
        case kVK_RightArrow: controller.step(by: 1)
        case kVK_UpArrow: controller.moveRow(by: -columns)
        case kVK_DownArrow: controller.moveRow(by: columns)
        default:
            // Letters work with the shortcut's modifiers still held.
            guard let action = controller.availableActions.first(where: { $0.keyCode == Int(event.keyCode) }) else { return false }
            controller.perform(action)
        }
        return true
    }

    private func makePanel() -> SwitcherKeyPanel {
        let panel = SwitcherKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Clicking anywhere else closes it without switching.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.lostFocus() }
        }
        return panel
    }

    /// Covers a display just under the switcher; clicks pass through it.
    private func makePeekPanel(on screen: NSScreen, controller: WindowSwitcherController) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setFrame(screen.frame, display: false)
        panel.contentView = NSHostingView(rootView: PeekView(controller: controller, screenOrigin: Displays.flip(screen.frame).origin))
        return panel
    }
}

/// Borderless panels refuse key status unless told otherwise, and the switcher needs the keys.
private final class SwitcherKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Styles

private let selectionSpring = Animation.spring(duration: 0.24, bounce: 0.15)

/// The rounded material both styles sit on, scaling in as it appears.
private struct SwitcherChrome: ViewModifier {
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border.opacity(0.6)))
            .scaleEffect(hasAppeared || reducesMotion ? 1 : 0.94)
            .onAppear {
                withAnimation(.spring(duration: 0.18, bounce: 0.2)) { hasAppeared = true }
            }
    }
}

private struct SwitcherGridView: View {
    let controller: WindowSwitcherController
    let columns: Int
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let tile = SwitcherLayout.tileSize
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(tile.width), spacing: SwitcherLayout.spacing), count: columns),
                        spacing: SwitcherLayout.spacing
                    ) {
                        ForEach(controller.windows) { window in
                            SwitcherTile(
                                window: window, preview: controller.preview(of: window),
                                isSelected: window.id == controller.selected?.id, selection: selection
                            )
                            .frame(width: tile.width, height: tile.height)
                            .id(window.id)
                            .onTapGesture {
                                controller.select(window)
                                controller.commit()
                            }
                        }
                    }
                    .padding([.horizontal, .top], SwitcherLayout.padding)
                    // The highlight slides from tile to tile.
                    .animation(reducesMotion ? nil : selectionSpring, value: controller.selectedIndex)
                    .thinScrollers()
                }
                .onChange(of: controller.selectedIndex) {
                    if let id = controller.selected?.id { proxy.scrollTo(id) }
                }
            }
            ActionKeys(actions: controller.availableActions)
        }
        .modifier(SwitcherChrome())
    }
}

/// Windows one behind another, receding up and to the left and turned in perspective, the
/// selected one in front. Stepping on loops the front card round to the back of the stack.
private struct SwitcherStackView: View {
    let controller: WindowSwitcherController
    let stack: SwitcherLayout.Stack
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let count = controller.windows.count
        let visible = min(count, SwitcherLayout.stackDepth)
        VStack(spacing: 0) {
            ZStack {
                ForEach(Array(controller.windows.enumerated()), id: \.element.id) { index, window in
                    let depth = SwitcherLayout.depth(of: index, selected: controller.selectedIndex, count: count)
                    if depth < visible {
                        StackCard(window: window, preview: controller.preview(of: window), isFront: depth == 0)
                            .frame(width: stack.card.width, height: stack.card.height)
                            .rotation3DEffect(.degrees(22), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                            .scaleEffect(1 - 0.04 * CGFloat(depth))
                            .offset(stack.offset(depth: depth, visible: visible))
                            .opacity(1 - 0.09 * Double(depth))
                            .zIndex(-Double(depth))
                            .transition(.opacity)
                            .onTapGesture {
                                controller.select(window)
                                controller.commit()
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding([.horizontal, .top], SwitcherLayout.padding)
            .animation(reducesMotion ? nil : .spring(duration: 0.32, bounce: 0.12), value: controller.selectedIndex)

            if let window = controller.selected {
                HStack(spacing: 8) {
                    if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    }
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !window.title.isEmpty {
                        Text(window.appName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    StateBadge(state: window.state)
                    Text("\(controller.selectedIndex + 1) of \(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(.regularMaterial, in: Capsule())
                .frame(height: SwitcherLayout.titleHeight)
            }
            ActionKeys(actions: controller.availableActions)
                .background(.regularMaterial, in: Capsule())
                .fixedSize()
                .padding(.bottom, SwitcherLayout.padding)
        }
    }
}

private struct StackCard: View {
    let window: SwitcherWindow
    let preview: CGImage?
    let isFront: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        ZStack {
            shape.fill(Color(nsColor: .windowBackgroundColor))
            if let preview {
                Image(nsImage: NSImage(cgImage: preview, size: .zero))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(isFront ? Color.accentColor : Color.white.opacity(0.25), lineWidth: isFront ? 3 : 1))
        .shadow(color: .black.opacity(0.35), radius: 16, x: 8, y: 8)
    }
}

private struct SwitcherTile: View {
    let window: SwitcherWindow
    let preview: CGImage?
    let isSelected: Bool
    let selection: Namespace.ID

    var body: some View {
        let icon = NSRunningApplication(processIdentifier: window.pid)?.icon
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let preview {
                        Image(nsImage: NSImage(cgImage: preview, size: .zero))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 56, height: 56)
                            .opacity(window.state == .onScreen ? 1 : 0.6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if preview != nil, let icon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                        .offset(x: 4, y: 4)
                }
            }
            HStack(spacing: 4) {
                StateBadge(state: window.state)
                Text(window.title.isEmpty ? window.appName : window.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help("\(window.appName) — \(window.title)")
        }
        .padding(8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.25))
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Marks minimized windows and those of hidden apps.
private struct StateBadge: View {
    let state: SwitcherWindow.State

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String? {
        switch state {
        case .onScreen: nil
        case .minimized: "minus.square"
        case .hidden: "eye.slash"
        }
    }
}

/// The keys for acting on the selected window.
private struct ActionKeys: View {
    let actions: [WindowSwitcherController.Action]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(actions) { action in
                HStack(spacing: 4) {
                    Text(action.key)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .frame(minWidth: 16, minHeight: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                    Text(action.title)
                }
            }
            Spacer(minLength: 0)
            Text("Esc cancels")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, SwitcherLayout.padding)
        .frame(height: SwitcherLayout.footerHeight)
    }
}

// MARK: - Peek

/// Dims a display except where the selected window is, showing its preview there so it can be
/// seen even when other windows cover it. The opening slides from window to window.
private struct PeekView: View {
    let controller: WindowSwitcherController
    /// This display's top left in global coordinates.
    let screenOrigin: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let window = controller.selected
        let frame = window?.frame?.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
        let shape = RoundedRectangle(cornerRadius: 10)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.45)
                .mask {
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                        if let frame {
                            shape
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                }
            if let frame, let window {
                Group {
                    if let preview = controller.preview(of: window) {
                        Image(nsImage: NSImage(cgImage: preview, size: .zero)).resizable()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 3))
                .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reducesMotion ? nil : selectionSpring, value: controller.selectedIndex)
    }
}

extension WindowSwitcherController {
    fileprivate func preview(of window: SwitcherWindow) -> CGImage? {
        window.windowID.flatMap { previews[$0] }
    }
}
