import CoreGraphics
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
    static let isLaptop: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
}
