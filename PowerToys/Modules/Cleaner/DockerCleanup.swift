import Foundation

/// The docker command, where it's installed.
nonisolated struct DockerCLI: Sendable {
    let path: String
    /// Runs docker with the arguments; tests give a fake.
    var run: @Sendable (_ arguments: [String], _ timeout: Duration) async throws -> Command.Output

    init(path: String, run: (@Sendable ([String], Duration) async throws -> Command.Output)? = nil) {
        self.path = path
        self.run = run ?? { try await Command.run(path, $0, timeout: $1) }
    }

    /// Where Docker Desktop, Homebrew, Rancher Desktop, OrbStack and Colima put the command.
    static func candidates(home: URL) -> [String] {
        [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            home.appending(path: ".docker/bin/docker").path, home.appending(path: ".rd/bin/docker").path,
            home.appending(path: ".orbstack/bin/docker").path,
        ]
    }

    static func find(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> DockerCLI? {
        candidates(home: home).first(where: isExecutable).map { DockerCLI(path: $0) }
    }
}

/// Frees space Docker uses through Docker itself, never by touching its disk image, and only on
/// this Mac. By default only what nothing can miss goes: the build cache and untagged images no
/// container uses. Tagged images may not download again, so they go only when that's turned on.
/// Containers and volumes can hold data, so they're listed but left alone.
nonisolated enum DockerCleanup {
    static let buildCacheID = "docker:build-cache"
    static let imagesID = "docker:images"
    static let taggedImagesID = "docker:tagged-images"
    static let usedImagesID = "docker:used-images"
    static let taggedReason = "Tagged; may not download again"

    static let imagesArguments = ["system", "df", "-v", "--format", "{{json .Images}}"]
    static let endpointArguments = ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]

    static func scan(_ docker: DockerCLI?, prunesTagged: Bool = false) async -> CleanupScan {
        guard let docker else { return CleanupScan(items: [], unavailable: "Not installed") }
        if let elsewhere = await notLocal(docker) { return CleanupScan(items: [], unavailable: elsewhere) }
        async let summary = try? await docker.run(["system", "df", "--format", "{{json .}}"], .seconds(20))
        async let images = try? await docker.run(imagesArguments, .seconds(20))
        guard let output = await summary, output.status == 0 else { return CleanupScan(items: [], unavailable: "Not running") }
        // The summary's reclaimable images can count ones stopped containers still use, so
        // images are only offered from the per-image list.
        var items = items(fromDF: output.stdout).filter { $0.id != imagesID }
        if let images = await images, images.status == 0,
            let split = imageItems(fromImages: images.stdout, prunesTagged: prunesTagged)
        {
            items += split
        } else {
            items.append(CleanupItem(id: imagesID, name: "Images", size: 0, skipReason: "Couldn't list images"))
        }
        return CleanupScan(items: items.sorted { $0.size > $1.size })
    }

    /// Why Docker isn't to be cleaned from here: its current context is another machine, or that
    /// couldn't be checked. Nil when it's this Mac.
    static func notLocal(_ docker: DockerCLI) async -> String? {
        guard let output = try? await docker.run(endpointArguments, .seconds(10)), output.status == 0 else {
            return "Couldn't check where Docker runs"
        }
        let host = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.hasPrefix("unix://") ? nil : "Docker points at another machine"
    }

    /// Prunes what's cleanable and `mayDelete` allows, and returns the space Docker says it freed.
    /// Tagged images go only with `prunesTagged`, along with the untagged ones.
    static func clean(
        _ docker: DockerCLI?, mayDelete: (String) -> Bool, prunesTagged: Bool = false,
        report: (CleanupEvent.Kind, String) -> Void = { _, _ in }
    ) async -> Int64 {
        guard let docker else { return 0 }
        // Checked again, as the context can change after the list was made.
        if let elsewhere = await notLocal(docker) {
            report(.failed(elsewhere), "Docker")
            return 0
        }
        var commands: [(String, [String])] = []
        // --all, as the size shown is all unused build cache, not just orphaned pieces; it's
        // rebuilt as needed.
        if mayDelete(buildCacheID) { commands.append(("Build cache", ["builder", "prune", "--all", "--force"])) }
        if prunesTagged, mayDelete(taggedImagesID), mayDelete(imagesID) {
            commands.append(("Images no container uses", ["image", "prune", "--all", "--force"]))
        } else if mayDelete(imagesID) {
            // Without --all, only untagged images go.
            commands.append(("Untagged images", ["image", "prune", "--force"]))
        } else if prunesTagged, mayDelete(taggedImagesID) {
            // Docker can't remove tagged images without the untagged ones, so it says why.
            report(.failed("Tagged images go only together with untagged ones"), "Tagged images no container uses")
        }
        var freed: Int64 = 0
        for (name, arguments) in commands {
            guard let output = try? await docker.run(arguments, .seconds(300)), output.status == 0 else {
                report(.failed("Docker couldn't remove it"), name)
                continue
            }
            let bytes = reclaimed(fromPrune: output.stdout)
            report(.deleted(bytes), name)
            freed += bytes
        }
        return freed
    }

    /// Items from `docker system df --format '{{json .}}'`, one JSON object a line.
    static func items(fromDF output: String) -> [CleanupItem] {
        output.split(separator: "\n").compactMap { line -> CleanupItem? in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { return nil }
            let size = parseSize(row.reclaimable)
            switch row.type {
            case "Build Cache": return CleanupItem(id: buildCacheID, name: "Build cache", size: size, skipReason: nil)
            case "Images": return CleanupItem(id: imagesID, name: "Images no container uses", size: size, skipReason: nil)
            case "Containers":
                return CleanupItem(id: "docker:containers", name: "Stopped containers", size: size, skipReason: "May hold data")
            case "Local Volumes":
                return CleanupItem(id: "docker:volumes", name: "Unused volumes", size: size, skipReason: "Holds data")
            default: return nil
            }
        }
    }

    /// Images from `docker system df -v --format '{{json .Images}}'`, split into untagged ones no
    /// container uses, tagged ones no container uses, which go only with `prunesTagged`, and ones a
    /// container, even a stopped one, still uses.
    static func imageItems(fromImages output: String, prunesTagged: Bool = false) -> [CleanupItem]? {
        guard let rows = try? JSONDecoder().decode([ImageRow].self, from: Data(output.utf8)) else { return nil }
        var untagged: Int64 = 0
        var tagged: Int64 = 0
        var used: Int64 = 0
        for row in rows {
            // Layers shared with a kept image stay, so only the image's own count when known.
            // "0B" is real, for an image whose layers are all shared; only "N/A" means unknown.
            let unique = row.uniqueSize.flatMap { $0.first?.isNumber == true ? parseSize($0) : nil }
            let size = unique ?? parseSize(row.size)
            // A count Docker didn't work out is treated as in use.
            if row.containers.flatMap(Int.init) != 0 {
                used += size
            } else if (row.repository ?? "<none>") == "<none>" {
                untagged += size
            } else {
                tagged += size
            }
        }
        var items = [CleanupItem(id: imagesID, name: "Untagged images no container uses", size: untagged, skipReason: nil)]
        if tagged > 0 {
            items.append(
                CleanupItem(
                    id: taggedImagesID, name: "Tagged images no container uses", size: tagged,
                    skipReason: prunesTagged ? nil : taggedReason))
        }
        if used > 0 {
            items.append(
                CleanupItem(id: usedImagesID, name: "Images containers use", size: used, skipReason: "Remove their containers first"))
        }
        return items
    }

    /// The total from a prune's last lines: "Total reclaimed space: 1.2GB", or "Total: 1.2GB"
    /// from the builder.
    static func reclaimed(fromPrune output: String) -> Int64 {
        for line in output.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["Total reclaimed space:", "Total:"] where trimmed.hasPrefix(prefix) {
                return parseSize(String(trimmed.dropFirst(prefix.count)))
            }
        }
        return 0
    }

    /// Bytes from Docker's sizes, such as "1.234GB (52%)" or "512kB", which count in thousands.
    static func parseSize(_ text: String) -> Int64 {
        let text = text.trimmingCharacters(in: .whitespaces)
        let number = text.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return 0 }
        let unit = text.dropFirst(number.count).prefix { $0.isLetter }.uppercased()
        let powers = ["B": 0.0, "KB": 1, "MB": 2, "GB": 3, "TB": 4, "PB": 5]
        guard let power = powers[unit] else { return 0 }
        return Int64(value * pow(1000, power))
    }

    private struct ImageRow: Decodable {
        let containers: String?
        let repository: String?
        let size: String
        let uniqueSize: String?

        enum CodingKeys: String, CodingKey {
            case containers = "Containers"
            case repository = "Repository"
            case size = "Size"
            case uniqueSize = "UniqueSize"
        }
    }

    private struct Row: Decodable {
        let type: String
        let reclaimable: String

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case reclaimable = "Reclaimable"
        }
    }
}
