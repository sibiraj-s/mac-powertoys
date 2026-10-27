import Foundation
import Observation

/// The environment each shell, and apps, start with. Read when first shown, and on request.
@Observable
final class EnvironmentController {
    let loginShell: URL?
    let sources: [EnvSource]
    var selected: EnvSource
    private(set) var snapshots: [EnvSource: EnvSnapshot] = [:]
    private(set) var loading: Set<EnvSource> = []
    private(set) var errors: [EnvSource: String] = [:]

    @ObservationIgnored private let probe: any EnvironmentProbing
    @ObservationIgnored private let pathSources: () -> [String: String]
    @ObservationIgnored private let exists: (String) -> Bool

    /// `sources` defaults to the shells in /etc/shells, and apps.
    init(
        loginShell: URL? = EnvSource.loginShell,
        sources: [EnvSource]? = nil,
        probe: any EnvironmentProbing = LiveEnvironmentProbe(),
        pathSources: @escaping () -> [String: String] = PathEntry.liveSystemSources,
        exists: @escaping (String) -> Bool = EnvironmentController.folderExists
    ) {
        let sources = sources ?? EnvSource.available(
            loginShell: loginShell,
            etcShells: (try? String(contentsOf: URL(filePath: "/etc/shells"), encoding: .utf8)) ?? "",
            exists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
        self.loginShell = loginShell
        self.sources = sources
        selected = sources.first ?? .apps
        self.probe = probe
        self.pathSources = pathSources
        self.exists = exists
    }

    var snapshot: EnvSnapshot? { snapshots[selected] }

    var isLoading: Bool { loading.contains(selected) }

    var error: String? { errors[selected] }

    /// Reads a source unless it's been read already; `force` reads it again.
    func load(_ source: EnvSource, force: Bool = false) async {
        guard !loading.contains(source), force || snapshots[source] == nil else { return }
        loading.insert(source)
        defer { loading.remove(source) }
        do {
            let variables = try await probe.variables(for: source)
            snapshots[source] = EnvSnapshot(variables: variables, pathSources: pathSources(), exists: exists)
            errors[source] = nil
        } catch is CancellationError {
            // Another source was picked; this one is read again when it's shown.
        } catch {
            errors[source] = error.localizedDescription
        }
    }

    nonisolated static func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
