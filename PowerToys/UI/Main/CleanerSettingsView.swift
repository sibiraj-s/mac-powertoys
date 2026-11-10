import AppKit
import Charts
import SwiftUI

struct CleanerSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var sortsByMemory = false
    @State private var confirmingClean = false
    /// What the open confirmation lists, which is all the clean takes.
    @State private var pendingReview: CleanReview?
    @State private var showingProgress = false

    var body: some View {
        let cleaner = state.cleaner
        let isEnabled = state.isEnabled(.cleaner)
        let isBusy = cleaner.isScanning || cleaner.isCleaning
        let review = cleaner.nextReview

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                StorageCard(
                    storage: cleaner.storage, selectedSize: review.deleteSize,
                    trashesLeftovers: cleaner.selected.contains(.leftovers)
                ) {
                    Button("Clean \(CleanerController.format(review.deleteSize + review.trashSize))") {
                        pendingReview = review
                        confirmingClean = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || review.isEmpty)
                    .help("Quit apps first to free the most.")
                }
                if cleaner.isCleaning {
                    CleaningStrip { showingProgress = true }
                } else if let message = cleaner.error ?? cleaner.result {
                    // Usage problems clear on their own once readings work again.
                    let canDismiss = cleaner.actionError != nil || cleaner.error == nil
                    let hasDetails = cleaner.error == nil && !cleaner.cleanEvents.isEmpty
                    MessageBanner(
                        // A clean that left items behind is a warning, not a success.
                        message: message, isError: cleaner.error != nil || cleaner.cleanFailed > 0,
                        details: hasDetails ? { showingProgress = true } : nil,
                        dismiss: canDismiss ? { cleaner.dismissMessage() } : nil)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    SectionTitle("Clean up")
                    Spacer()
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else if let scannedAt = cleaner.scannedAt {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("Scanned \(scannedAt.formatted(.relative(presentation: .named)))")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                    }
                    Button("Rescan") { Task { await cleaner.scan() } }
                        .controlSize(.small)
                        .disabled(isBusy)
                }
                CardSection {
                    let largest = cleaner.sizes.values.max() ?? 0
                    ForEach(CleanupTarget.allCases) { target in
                        CleanupTargetRow(target: target, largest: largest)
                    }
                }
            }

            CardSection("Apps") {
                UninstallAppsRow()
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Usage")
                HStack(spacing: 12) {
                    UsageTile(
                        title: "CPU", fraction: cleaner.cpu, history: cleaner.cpuHistory,
                        caption: "Last 2 minutes · \(ProcessInfo.processInfo.activeProcessorCount) cores"
                    ) {
                        EmptyView()
                    }
                    UsageTile(
                        title: "Memory", fraction: cleaner.memory?.fraction, history: cleaner.memoryHistory,
                        caption: cleaner.memory.map(memoryText) ?? "—"
                    ) {
                        EmptyView()
                    }
                }
            }

            CardSection("Busiest processes") {
                let processes = sortsByMemory ? cleaner.topByMemory : cleaner.topByCPU
                let busiest = processes.map(\.cpu).max() ?? 0
                ProcessHeader(sortsByMemory: $sortsByMemory)
                ForEach(processes) { process in
                    ProcessUsageRow(process: process, busiest: busiest)
                }
            }
        }
        // Only while the module is on.
        .task(id: isEnabled) {
            guard isEnabled else { return }
            // Both stop when the page goes away or the module is turned off.
            await state.cleaner.watchAndScan()
        }
        .sheet(isPresented: $showingProgress) {
            CleanProgressSheet()
        }
        .confirmationDialog(
            confirmationTitle(pendingReview ?? review), isPresented: $confirmingClean, presenting: pendingReview
        ) { confirmed in
            Button(confirmed.deleteSize > 0 ? "Delete" : "Move to Trash", role: .destructive) {
                Task { await cleaner.clean(confirmed) }
            }
        } message: { confirmed in
            Text(confirmationMessage(confirmed))
        }
    }

    private func confirmationTitle(_ review: CleanReview) -> String {
        review.deleteSize > 0
            ? "Delete \(CleanerController.format(review.deleteSize))?"
            : "Move \(CleanerController.format(review.trashSize)) to the Trash?"
    }

    private func confirmationMessage(_ review: CleanReview) -> String {
        var parts: [String] = []
        if review.deleteSize > 0 {
            parts.append("The ticked items are deleted for good. Apps and tools make these files again as they need them.")
        }
        if review.trashSize > 0 {
            parts.append(
                "\(CleanerController.format(review.trashSize)) of uninstalled app leftovers goes to the Trash, and frees space once it's emptied."
            )
        }
        return parts.joined(separator: " ")
    }

    private func memoryText(_ memory: MemoryUsage) -> String {
        "\(CleanerController.format(Int64(memory.used))) of \(CleanerController.format(Int64(memory.total)))"
    }
}

/// The accent color, then orange from 75% and red from 90%.
private func usageTint(_ fraction: Double) -> Color {
    switch fraction {
    case 0.9...: .red
    case 0.75...: .orange
    default: .accentColor
    }
}

private func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
}

/// A thin bar filled to `fraction` of its width.
private struct FillBar: View {
    let fraction: Double
    let width: CGFloat
    var tint: Color = .accentColor

    var body: some View {
        Capsule()
            .fill(Palette.divider)
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: width * min(1, max(0, fraction)))
            }
            .accessibilityHidden(true)
    }
}

/// A small grey label, such as why something is left alone.
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.sidebar))
    }
}

/// A rounded square holding a target's symbol.
struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5))
            .foregroundStyle(Palette.secondaryText)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27).fill(Palette.sidebar))
            .accessibilityHidden(true)
    }
}

extension CleanupTarget {
    fileprivate var symbol: String {
        switch self {
        case .caches: "archivebox"
        case .logs: "doc.text"
        case .xcode: "hammer"
        case .developerCaches: "shippingbox"
        case .docker: "square.stack.3d.up"
        case .leftovers: "app.dashed"
        }
    }
}

/// Free space on the startup disk, a bar of used, selected and available space, and the clean
/// button, since cleaning is what changes the bar.
private struct StorageCard<Action: View>: View {
    let storage: StorageUsage?
    let selectedSize: Int64
    let trashesLeftovers: Bool
    @ViewBuilder var action: Action

    private static var usedColor: Color { .gray }

    var body: some View {
        let format = CleanerController.format
        // The selection is part of the used space, so it can't be more than that.
        let selected = min(selectedSize, storage?.used ?? 0)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Startup disk")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(storage.map { format($0.available) } ?? "—")
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        if let storage {
                            Text("available of \(format(storage.total))")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    action
                    Text(trashesLeftovers ? "Deleted for good, except app leftovers" : "Deleted for good, not moved to the Trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .help(trashesLeftovers ? "Uninstalled app leftovers go to the Trash, so they can be put back." : "")
                }
            }

            GeometryReader { geometry in
                let total = Double(max(1, storage?.total ?? 1))
                let width = geometry.size.width
                HStack(spacing: 0) {
                    Rectangle().fill(Self.usedColor)
                        .frame(width: width * Double((storage?.used ?? 0) - selected) / total)
                    Rectangle().fill(Color.accentColor)
                        .frame(width: width * Double(selected) / total)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(Palette.off.opacity(0.5))
            .clipShape(Capsule())
            .accessibilityElement()
            .accessibilityLabel("Storage \(percent(storage?.fraction ?? 0)) used")

            if let storage {
                HStack(spacing: 18) {
                    legend("Used \(format(storage.used - selected))", Self.usedColor)
                    legend("Selected to clean \(format(selected))", .accentColor)
                    legend("Available \(format(storage.available))", Palette.off)
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border))
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

/// Shown while a clean runs: how much it has freed and what it's on. Clicking it shows the details.
private struct CleaningStrip: View {
    let showDetails: () -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        let cleaner = state.cleaner
        let latest = cleaner.cleanEvents.last {
            switch $0.kind {
            case .deleted, .trashed: true
            default: false
            }
        }
        Button(action: showDetails) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Cleaning… \(CleanerController.format(cleaner.cleanFreed)) freed")
                    .monospacedDigit()
                if let latest {
                    Text(URL(filePath: latest.detail).lastPathComponent)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("Details").foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show what's being cleaned")
    }
}

/// Each target of the current or last clean with where it's at, and a live list of what was
/// deleted and what stayed.
private struct CleanProgressSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let cleaner = state.cleaner
        let items = cleaner.cleanEvents.filter {
            switch $0.kind {
            case .deleted, .trashed, .failed, .skipped, .timedOut: true
            case .started, .finished: false
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cleaner.isCleaning ? "Cleaning…" : "Cleaned").font(.system(size: 14, weight: .semibold))
                    Text(
                        cleaner.cleanTrashed > 0
                            ? "Freed, plus \(CleanerController.format(cleaner.cleanTrashed)) moved to the Trash"
                            : "Deleted for good, not moved to the Trash"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                }
                Spacer()
                if cleaner.isCleaning {
                    ProgressView().controlSize(.small)
                }
                Text(CleanerController.format(cleaner.cleanFreed))
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
            }
            .padding(16)

            Divider()

            VStack(spacing: 0) {
                ForEach(cleaner.cleanedTargets) { target in
                    HStack(spacing: 10) {
                        SymbolTile(symbol: target.symbol, size: 22)
                        Text(target.title).font(.system(size: 12))
                        Spacer()
                        progressView(cleaner.cleanProgress(of: target))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                }
            }
            .padding(.vertical, 4)

            Divider()

            Text("Activity")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if items.isEmpty {
                Text(cleaner.isCleaning ? "Nothing deleted yet." : "Nothing was deleted.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(items) { event in
                                CleanEventRow(event: event).id(event.id)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    // Follows along as items are deleted.
                    .onChange(of: items.last?.id) { _, last in
                        if let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("Show Log File") {
                    if let log = state.cleaner.logFile { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                }
                .disabled(!(state.cleaner.logFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false))
                .help("Every deletion, with its date and size")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 480)
    }

    @ViewBuilder
    private func progressView(_ progress: CleanProgress) -> some View {
        switch progress {
        case .waiting:
            Text("Waiting").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
        case .cleaning:
            ProgressView().controlSize(.mini)
        case .done(let freed):
            HStack(spacing: 6) {
                Text(CleanerController.format(freed)).font(.system(size: 12).monospacedDigit())
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.on)
            }
            .foregroundStyle(Palette.secondaryText)
        case .stillDeleting:
            Label("Still deleting", systemImage: "clock")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .help("Took too long to wait for. It stops after the item it's on; the log lists what went.")
        }
    }
}

/// One deleted or skipped item: when, where and how much, or why it stayed.
private struct CleanEventRow: View {
    let event: CleanupEvent

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        let path =
            event.detail.hasPrefix(Self.home) ? "~" + event.detail.dropFirst(Self.home.count) : event.detail
        HStack(spacing: 8) {
            Text(event.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                .foregroundStyle(Palette.secondaryText)
            switch event.kind {
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(path).lineLimit(1).truncationMode(.middle).help(event.detail)
                Spacer(minLength: 8)
                Text(reason).foregroundStyle(Palette.secondaryText)
            case .timedOut:
                Image(systemName: "clock").foregroundStyle(.orange)
                Text("\(event.target.title) took too long; still deleting in the background")
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
            case .skipped(let reason):
                Image(systemName: "lock").foregroundStyle(Palette.secondaryText)
                Text(path).lineLimit(1).truncationMode(.middle).help(event.detail).foregroundStyle(Palette.secondaryText)
                Spacer(minLength: 8)
                Text("Kept: \(reason)").foregroundStyle(Palette.secondaryText)
            default:
                Image(systemName: "trash").foregroundStyle(Palette.secondaryText)
                Text(path).lineLimit(1).truncationMode(.middle).help(event.detail)
                Spacer(minLength: 8)
                if case .deleted(let bytes) = event.kind {
                    Text(CleanerController.format(bytes)).foregroundStyle(Palette.secondaryText)
                } else if case .trashed(let bytes) = event.kind {
                    Text("\(CleanerController.format(bytes)) to Trash").foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 16)
        .frame(height: 22)
    }
}

/// A title, the latest reading, a graph of recent ones with the newest on the right, and a caption.
private struct UsageTile<Trailing: View>: View {
    let title: String
    let fraction: Double?
    let history: [Double]
    let caption: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let tint = usageTint(history.last ?? 0)
        // Readings line up on the right, so the graph fills in from there as they arrive.
        let offset = CleanerController.historyLength - history.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(fraction.map(percent) ?? "—")
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle((fraction ?? 0) >= 0.75 ? tint : Color.primary)
            }
            Chart(Array(history.enumerated()), id: \.offset) { index, reading in
                AreaMark(x: .value("Time", index + offset), y: .value(title, reading))
                    .foregroundStyle(tint.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", index + offset), y: .value(title, reading))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            .chartXScale(domain: 0...(CleanerController.historyLength - 1))
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0.5]) { _ in
                    AxisGridLine().foregroundStyle(Palette.divider)
                }
            }
            .frame(height: 44)
            .accessibilityLabel("\(title) over the last two minutes")
            HStack {
                Text(caption)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
                Spacer()
                trailing
            }
            .frame(minHeight: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    }
}

/// A cleanup target: its checkbox, size compared with the largest target, and a button that
/// opens the list of what's in it. Clicking the row opens the list too.
private struct CleanupTargetRow: View {
    let target: CleanupTarget
    let largest: Int64

    @Environment(AppState.self) private var state
    @State private var isShowingItems = false
    @State private var isAskingForAccess = false

    var body: some View {
        let cleaner = state.cleaner
        let unavailable = cleaner.scans[target]?.unavailable
        let isSelected = unavailable == nil && cleaner.selected.contains(target)
        CardRow {
            HStack(spacing: 12) {
                Toggle(
                    target.title,
                    isOn: Binding(
                        get: { isSelected },
                        set: { if !cleaner.setSelected($0, target) { isAskingForAccess = true } })
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(unavailable != nil)
                .sheet(isPresented: $isAskingForAccess) {
                    FullDiskAccessSheet(target: target)
                }
                SymbolTile(symbol: target.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title).font(.system(size: 13))
                    Text(target.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .help(target.hint)
                }
            }
            .opacity(unavailable == nil ? 1 : 0.6)
        } trailing: {
            HStack(spacing: 10) {
                if let unavailable {
                    Tag(text: unavailable)
                } else if let size = cleaner.sizes[target] {
                    let kept = cleaner.scans[target]?.items.filter { $0.skipReason != nil }.count ?? 0
                    if kept > 0 {
                        Tag(text: "\(kept) kept")
                            .help("Left alone, such as what macOS protects or what's in use. Click to see why.")
                    }
                    FillBar(
                        fraction: largest > 0 ? Double(size) / Double(largest) : 0, width: 80,
                        tint: isSelected ? .accentColor : Palette.off)
                    Text(size == 0 ? "Empty" : CleanerController.format(size))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: 64, alignment: .trailing)
                } else {
                    Text("—").foregroundStyle(Palette.secondaryText)
                }
                Button {
                    isShowingItems = true
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.secondaryText)
                .help("Show what it cleans")
                .accessibilityLabel("Show what's in \(target.title)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isShowingItems = true }
        .sheet(isPresented: $isShowingItems) {
            CleanupItemsSheet(target: target)
        }
    }
}

/// Asks for Full Disk Access when a target that needs it is checked, and checks it once it's
/// granted.
private struct FullDiskAccessSheet: View {
    let target: CleanupTarget

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text("Full Disk Access needed").font(.system(size: 14, weight: .semibold))
            }
            Text(
                "macOS only lets apps with Full Disk Access remove what uninstalled apps left in their containers. Turn it on for PowerToys in System Settings, and \(target.title) is checked as soon as it's on."
            )
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            Text("If it's on but this stays open, quit and reopen PowerToys.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for access…").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Settings") { state.permissions.openSettings(for: .fullDiskAccess) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            // Checked again every second, as System Settings doesn't say when it changes.
            while !Task.isCancelled {
                if state.cleaner.setSelected(true, target) {
                    state.permissions.refresh()
                    // Started on its own, as closing the sheet cancels this task.
                    let cleaner = state.cleaner
                    Task { await cleaner.scan([target]) }
                    dismiss()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Everything in a cleanup target, largest first, each with a checkbox. Unticked items are kept
/// in later cleanups too; protected ones are listed apart with why they're left alone.
private struct CleanupItemsSheet: View {
    let target: CleanupTarget

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let cleaner = state.cleaner
        let items = cleaner.scans[target]?.items ?? []
        let cleanable = items.filter { $0.skipReason == nil }
        let leftAlone = items.filter { $0.skipReason != nil }
        let ticked = cleanable.filter(cleaner.willClean)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(symbol: target.symbol, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title).font(.system(size: 14, weight: .semibold))
                    Text(target.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // What's ticked, as the row and the footer show.
                Text(CleanerController.format(cleaner.sizes[target] ?? 0))
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
            }
            .padding(16)

            if target == .docker {
                Toggle(
                    isOn: Binding(
                        get: { cleaner.dockerPrunesTagged },
                        set: { prunesTagged in Task { await cleaner.setDockerPrunesTagged(prunesTagged) } })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also remove tagged images no container uses").font(.system(size: 12))
                        Text("Off, only untagged images and the build cache go. Tagged images you built or pulled may not download again.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            if items.contains(where: { $0.skipReason == AppLeftovers.needsFullDiskAccess }) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("macOS only lets apps with Full Disk Access remove other apps' containers. Grant it, then rescan.")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open Settings") { state.permissions.openSettings(for: .fullDiskAccess) }
                        .controlSize(.small)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            if items.isEmpty {
                Divider()
                Text(emptyText(cleaner.scans[target]))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    if cleanable.isEmpty {
                        Text("Name")
                    } else {
                        Toggle(
                            "Name",
                            isOn: Binding(
                                get: { ticked.count == cleanable.count },
                                set: { cleaner.setWillCleanAll($0, in: target) })
                        )
                        .toggleStyle(.checkbox)
                        .help("Select all")
                    }
                    Spacer()
                    Text("Size").frame(width: 64, alignment: .trailing)
                    Color.clear.frame(width: 16, height: 1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(Palette.sidebar.opacity(0.6))
                .overlay(alignment: .top) { Divider() }
                .overlay(alignment: .bottom) { Divider() }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(cleanable) { item in
                            CleanupItemRow(item: item)
                        }
                        if !leftAlone.isEmpty {
                            Text("Left alone")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.secondaryText)
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                            ForEach(leftAlone) { item in
                                CleanupItemRow(item: item)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Text("\(ticked.count) of \(cleanable.count) selected · \(CleanerController.format(cleaner.sizes[target] ?? 0))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 460)
    }

    private func emptyText(_ scan: CleanupScan?) -> String {
        guard let scan else { return "Not scanned yet." }
        if let unavailable = scan.unavailable {
            // "Docker is not running", but other reasons read as they are.
            let saysWhatDockerIs = target == .docker && ["Not installed", "Not running"].contains(unavailable)
            return saysWhatDockerIs ? "Docker is \(unavailable.lowercased())." : "\(unavailable)."
        }
        return "Nothing to clean."
    }
}

/// One file or folder in a target: a checkbox when it can be cleaned, or a lock and the reason
/// it's left alone.
private struct CleanupItemRow: View {
    let item: CleanupItem

    @Environment(AppState.self) private var state

    var body: some View {
        let cleaner = state.cleaner
        let willClean = cleaner.willClean(item)
        HStack(spacing: 10) {
            if item.skipReason == nil {
                Toggle(item.name, isOn: Binding(get: { willClean }, set: { cleaner.setWillClean($0, item) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 10))
                    .frame(width: 14)
            }
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.url?.path ?? item.name)
            Spacer(minLength: 8)
            if let reason = item.skipReason {
                Tag(text: reason)
            }
            Text(CleanerController.format(item.size))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Group {
                if let url = item.url {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)
        }
        .font(.system(size: 12))
        .foregroundStyle(willClean ? Color.primary : Palette.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider).frame(height: 1)
        }
    }
}

/// Column titles for the processes; clicking CPU or Memory sorts by it.
private struct ProcessHeader: View {
    @Binding var sortsByMemory: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            sortButton("CPU", isOn: !sortsByMemory) { sortsByMemory = false }
                .frame(width: ProcessColumns.cpu, alignment: .trailing)
            sortButton("Memory", isOn: sortsByMemory) { sortsByMemory = true }
                .frame(width: ProcessColumns.memory, alignment: .trailing)
            Color.clear.frame(width: ProcessColumns.quit, height: 1)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Palette.sidebar.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider).frame(height: 1)
        }
    }

    private func sortButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if isOn {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
            .fontWeight(isOn ? .semibold : .regular)
            .foregroundStyle(isOn ? Color.primary : Palette.secondaryText)
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private enum ProcessColumns {
    static let cpu: CGFloat = 110
    static let memory: CGFloat = 72
    static let quit: CGFloat = 16
}

private struct ProcessUsageRow: View {
    let process: ProcessUsage
    /// The highest CPU in the list, which fills the bar.
    let busiest: Double

    @Environment(AppState.self) private var state

    var body: some View {
        let cleaner = state.cleaner
        let name = NSRunningApplication(processIdentifier: process.pid)?.localizedName ?? process.name
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ProcessIcon(pid: process.pid, size: 18)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .help(process.path)
                if cleaner.quitting.contains(process.pid) {
                    Text("Quitting…").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                FillBar(fraction: busiest > 0 ? process.cpu / busiest : 0, width: 50)
                Text(process.cpu.formatted(.number.precision(.fractionLength(1))) + "%")
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(width: ProcessColumns.cpu, alignment: .trailing)
            Text(CleanerController.format(process.memory))
                .frame(width: ProcessColumns.memory, alignment: .trailing)
            Button {
                cleaner.quit(process)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .frame(width: ProcessColumns.quit)
            .disabled(!cleaner.canQuit(process) || cleaner.quitting.contains(process.pid))
            .help(
                cleaner.canQuit(process)
                    ? "Quit \(name)" : process.uid != getuid() ? "Run by another user" : "Part of macOS"
            )
            .accessibilityLabel("Quit \(name)")
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider).frame(height: 1)
        }
    }
}
