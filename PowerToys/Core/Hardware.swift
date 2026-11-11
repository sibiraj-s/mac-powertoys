import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

/// Facts about the Mac itself, shared by modules that need them.
nonisolated enum Hardware {
    /// Whether a display other than the Mac's own screen is connected. Displays that are plugged in
    /// but asleep count; an iPad (Sidecar) or AirPlay screen counts too, as macOS doesn't set them apart.
    static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Whether this Mac runs on a battery: a laptop rather than a desktop, whose only screens are external.
    static let isLaptop: Bool = internalBattery() != nil

    /// The battery's charge in percent while the Mac runs on it; nil on power or without a battery.
    /// On battery with a charge that can't be read, 0, so callers guarding against a flat battery stay careful.
    static func batteryPercentOnBattery() -> Int? {
        guard let battery = internalBattery(),
            battery[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        else { return nil }
        guard let current = battery[kIOPSCurrentCapacityKey] as? Int,
            let max = battery[kIOPSMaxCapacityKey] as? Int, max > 0
        else { return 0 }
        return current * 100 / max
    }

    /// The built-in battery's power source description, if the Mac has one.
    private static func internalBattery() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        return sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    }

    /// Puts the Mac to sleep if its lid is closed, which needs no administrator rights.
    static func sleepIfLidClosed() {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return }
        defer { IOObjectRelease(root) }
        let closed =
            IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        guard closed == true else { return }
        Task {
            do {
                let output = try await Command.run("/usr/bin/pmset", ["sleepnow"], timeout: .seconds(10))
                if output.status != 0 { NSLog("Awake: pmset sleepnow failed (\(output.status)): \(output.stderr)") }
            } catch {
                NSLog("Awake: pmset sleepnow failed: \(error)")
            }
        }
    }
}

/// Calls `onChange` whenever the power source or the battery's charge changes.
final class PowerSourceWatcher {
    private final class Handler {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    }

    private let handler: Handler
    private let source: CFRunLoopSource?

    init(onChange: @escaping () -> Void) {
        handler = Handler(onChange)
        // Delivered on the main run loop, where it's added.
        source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                MainActor.assumeIsolated { Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue().onChange() }
            }, Unmanaged.passUnretained(handler).toOpaque()
        )?.takeRetainedValue()
        // Common modes, so it still arrives while a menu is open.
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    isolated deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
