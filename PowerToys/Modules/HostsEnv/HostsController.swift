import Foundation
import Observation

/// Reads and writes the hosts file; a protocol so tests don't ask for a password.
protocol HostsStore: Sendable {
    func read() throws -> String
    /// Replaces the hosts file and flushes the DNS cache, if the file still reads `expected`.
    /// Throws `HostsChangedError` if it doesn't, and `CancellationError` when the password prompt
    /// is cancelled.
    func write(_ text: String, replacing expected: String) async throws
    func flushDNS() async throws
}

/// The hosts file changed since it was read.
struct HostsChangedError: Error {}

nonisolated struct LiveHostsStore: HostsStore {
    private static let changedMarker = "POWERTOYS_HOSTS_CHANGED"

    private static let flushCommand = "(/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder; true)"

    func read() throws -> String {
        try String(contentsOf: URL(filePath: HostsFile.path), encoding: .utf8)
    }

    func write(_ text: String, replacing expected: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appending(path: "new")
        let original = directory.appending(path: "expected")
        try text.write(to: staged, atomically: true, encoding: .utf8)
        try expected.write(to: original, atomically: true, encoding: .utf8)
        // Compared as root, after the password prompt, so a change made while it was open isn't
        // overwritten. cp into the existing file keeps its owner and permissions.
        let command = """
            if /usr/bin/cmp -s \(Command.shellQuoted(original.path)) \(HostsFile.path); then \
            /bin/cp \(Command.shellQuoted(staged.path)) \(HostsFile.path) && \(Self.flushCommand); \
            else echo \(Self.changedMarker) >&2; exit 1; fi
            """
        do {
            try await Command.runAsAdministrator(command, prompt: "PowerToys wants to update the hosts file.")
        } catch let error as CommandError where error.errorDescription?.contains(Self.changedMarker) == true {
            throw HostsChangedError()
        }
    }

    func flushDNS() async throws {
        try await Command.runAsAdministrator(Self.flushCommand, prompt: "PowerToys wants to flush the DNS cache.")
    }
}

/// The hosts file as last read, and changes to it. Every change is saved straight away.
@Observable
final class HostsController {
    private(set) var file = HostsFile(text: "")
    private(set) var isLoaded = false
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var hasBackup: Bool

    @ObservationIgnored private let store: any HostsStore
    @ObservationIgnored let backupURL: URL?
    /// The file's text when last read or written, to notice changes made elsewhere.
    @ObservationIgnored private var lastText: String?

    static var defaultBackupURL: URL {
        URL.powerToysSupportDirectory.appending(path: "hosts.original")
    }

    init(store: any HostsStore = LiveHostsStore(), backupURL: URL? = HostsController.defaultBackupURL) {
        self.store = store
        self.backupURL = backupURL
        hasBackup = backupURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Picks up changes made elsewhere. Unchanged text keeps the entries as they are.
    func reload() {
        do {
            let text = try store.read()
            if text != lastText {
                file = HostsFile(text: text, reusingIDsFrom: isLoaded ? file : nil)
                lastText = text
            }
            isLoaded = true
            if !isSaving { error = nil }
        } catch {
            self.error = "Couldn't read \(HostsFile.path): \(error.localizedDescription)"
        }
    }

    /// Whether an entry is still in the file, rather than changed or removed elsewhere.
    func contains(_ id: HostEntry.ID) -> Bool {
        file.entry(id) != nil
    }

    /// Makes a change and saves it, which asks for an administrator password. If saving fails
    /// or is cancelled, nothing changes. Returns whether the change was saved.
    @discardableResult
    func change(_ edit: (inout HostsFile) -> Void) async -> Bool {
        guard !isSaving else { return false }
        var updated = file
        edit(&updated)
        guard updated != file else { return true }

        // Don't overwrite what someone else changed since we read it. Checked here to skip the
        // password prompt, and again by the store once it has the password.
        guard let expected = lastText, (try? store.read()) == expected else {
            reloadAfterOutsideChange()
            return false
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try backUpIfNeeded()
            try await store.write(updated.text, replacing: expected)
            file = updated
            lastText = updated.text
            error = nil
            return true
        } catch is CancellationError {
            return false
        } catch is HostsChangedError {
            isSaving = false
            reloadAfterOutsideChange()
            return false
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    private func reloadAfterOutsideChange() {
        reload()
        error = "The hosts file was changed elsewhere, so it's been reloaded. Try again."
    }

    /// Puts back the hosts file as it was before PowerToys first changed it.
    @discardableResult
    func restoreOriginal() async -> Bool {
        guard let backupURL, let original = try? String(contentsOf: backupURL, encoding: .utf8) else { return false }
        return await change { $0 = HostsFile(text: original) }
    }

    func flushDNS() async {
        do {
            try await store.flushDNS()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = "Couldn't flush the DNS cache: \(error.localizedDescription)"
        }
    }

    private func backUpIfNeeded() throws {
        guard let backupURL, !hasBackup, let lastText else { return }
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lastText.write(to: backupURL, atomically: true, encoding: .utf8)
        hasBackup = true
    }
}
