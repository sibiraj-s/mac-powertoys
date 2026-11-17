import AppKit
import Darwin
import Foundation
import Observation

/// Bytes received and sent by the Mac's network interfaces since they came up.
nonisolated struct InterfaceCounters: Hashable, Sendable {
    var bytesIn: UInt64
    var bytesOut: UInt64

    /// Interfaces that carry traffic out of the Mac: Ethernet and Wi‑Fi (en), cellular (pdp_ip)
    /// and PPP. Tunnels such as a VPN's are left out, as their traffic also crosses one of these.
    static func counts(_ name: String) -> Bool {
        ["en", "pdp_ip", "ppp"].contains { name.hasPrefix($0) }
    }

    /// Sums the 64-bit counters from the routing table's interface list, which any user can read.
    static func read() -> InterfaceCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        var total = InterfaceCounters(bytesIn: 0, bytesOut: 0)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil, counts(String(nulTerminated: name)) {
                        total.bytesIn &+= message.ifm_data.ifi_ibytes
                        total.bytesOut &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return total
    }
}

/// The whole Mac's download and upload speed, for the menu bar. Samples once a second, only
/// while it's shown there.
@Observable
final class NetworkSpeedMonitor {
    /// Bytes a second.
    private(set) var download: Double = 0
    private(set) var upload: Double = 0
    private(set) var isRunning = false

    var showsInMenuBar: Bool {
        didSet { defaults.set(showsInMenuBar, forKey: Self.showsInMenuBarKey) }
    }

    static let showsInMenuBarKey = "network.speedInMenuBar"
    static let interval: Duration = .seconds(1)

    private let defaults: UserDefaults
    @ObservationIgnored private let read: () -> InterfaceCounters?
    @ObservationIgnored private var last: (counters: InterfaceCounters, at: ContinuousClock.Instant)?
    @ObservationIgnored private var sampling: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, read: @escaping () -> InterfaceCounters? = InterfaceCounters.read) {
        self.defaults = defaults
        self.read = read
        showsInMenuBar = defaults.bool(forKey: Self.showsInMenuBarKey)
    }

    func start() {
        guard sampling == nil else { return }
        isRunning = true
        last = nil
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                // Ends once nothing holds the monitor.
                guard let monitor = self else { return }
                monitor.sample()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        sampling?.cancel()
        sampling = nil
        isRunning = false
        last = nil
        download = 0
        upload = 0
    }

    func sample(at now: ContinuousClock.Instant = .now) {
        guard let counters = read() else { return }
        record(counters, at: now)
    }

    /// Works out speeds against the previous sample. Counters that went down, as when an
    /// interface went away, start over rather than count as a burst, and show nothing moving.
    func record(_ counters: InterfaceCounters, at now: ContinuousClock.Instant) {
        defer { last = (counters, now) }
        guard let last else { return }
        let elapsed = (now - last.at) / .seconds(1)
        guard elapsed > 0 else { return }
        guard counters.bytesIn >= last.counters.bytesIn, counters.bytesOut >= last.counters.bytesOut else {
            download = 0
            upload = 0
            return
        }
        download = Double(counters.bytesIn - last.counters.bytesIn) / elapsed
        upload = Double(counters.bytesOut - last.counters.bytesOut) / elapsed
    }

    /// "0 KB/s", "340 KB/s", "1.2 MB/s", "52 MB/s": short and steady, for the menu bar. Each
    /// unit is chosen by the number as rounded, so 999.6 KB/s reads "1.0 MB/s", not "1000 KB/s".
    static func compact(_ bytesPerSecond: Double) -> String {
        let kilobytes = (bytesPerSecond / 1_000).rounded()
        if kilobytes < 1_000 { return "\(Int(kilobytes)) KB/s" }
        let megabytes = bytesPerSecond / 1_000_000
        if (megabytes * 10).rounded() < 100 { return String(format: "%.1f MB/s", megabytes) }
        if megabytes.rounded() < 1_000 { return "\(Int(megabytes.rounded())) MB/s" }
        return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
    }

    /// "628 B/s", "2.1 KB/s", "1.2 MB/s", or "–" when nothing moved: for lists of apps. Units
    /// are chosen by the number as rounded, like `compact`.
    static func detailed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "–" }
        if bytesPerSecond.rounded() < 1_000 { return "\(Int(bytesPerSecond.rounded())) B/s" }
        for (unit, size) in [("KB", 1e3), ("MB", 1e6)] where (bytesPerSecond / size * 10).rounded() < 10_000 {
            return String(format: "%.1f \(unit)/s", bytesPerSecond / size)
        }
        return String(format: "%.1f GB/s", bytesPerSecond / 1e9)
    }
}

/// Upload over download in two small lines, drawn as a template image so the menu bar tints it.
/// A fixed width keeps the items beside it from shifting as the numbers change.
enum NetworkSpeedImage {
    static func make(download: Double, upload: Double) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style]
        let size = NSSize(width: 58, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let lineHeight = rect.height / 2
            ("↑ " + NetworkSpeedMonitor.compact(upload) as NSString).draw(
                in: NSRect(x: 0, y: lineHeight - 1, width: rect.width, height: lineHeight), withAttributes: attributes)
            ("↓ " + NetworkSpeedMonitor.compact(download) as NSString).draw(
                in: NSRect(x: 0, y: 0, width: rect.width, height: lineHeight), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription =
            "Download \(NetworkSpeedMonitor.compact(download)), upload \(NetworkSpeedMonitor.compact(upload))"
        return image
    }
}

extension String {
    /// A C string read into a fixed buffer, up to its first NUL.
    nonisolated init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
