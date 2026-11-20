import Darwin
import Foundation

/// What apps leave behind in /tmp and the person's own temporary folder. macOS no longer clears
/// either while the Mac stays on, and apps forget to, so they fill up.
///
/// Each item there is gone through, however deep. What hasn't been used for `unusedFor` goes, a
/// folder whole when nothing in it has been used since; a folder with something newer in it
/// stays, and only its older parts go. Asked to clean everything, age doesn't count. Either
/// way a socket or pipe, which is how a running app is reached, stays with the folders it's in,
/// as does anything of another user's, on another disk or that can't be changed.
nonisolated enum TemporaryFiles {
    /// How long something is left unused before it goes, as macOS once cleared /tmp.
    static let unusedFor: TimeInterval = 3 * 24 * 60 * 60
    /// The same in days, as it's told.
    static var unusedForDays: Int { Int(unusedFor / (24 * 60 * 60)) }

    /// /tmp and the person's own temporary folder, by their real paths, which open files are
    /// listed by. The own folder is the one macOS made for this user, not wherever TMPDIR
    /// points, which can be set to any folder; and only if it's where macOS keeps them.
    static func folders() -> [URL] {
        var paths = ["/private/tmp"]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0, let own = realpath(buffer, nil) {
            let path = String(cString: own)
            free(own)
            if path.hasPrefix("/private/var/folders/") { paths.append(path) }
        }
        // One inside the other, as when the temporary folder is set to one in /tmp, is gone
        // through as part of that.
        let unique = Set(paths)
        return unique.filter { path in !unique.contains { path.hasPrefix($0 + "/") } }.sorted()
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// Items left alone whatever their age: hidden ones, such as lock files and the X11 folder,
    /// macOS's own, the folder apps keep documents being saved in, and this app's own.
    static func protects(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("com.apple.") || name == "TemporaryItems" || name.hasPrefix("PowerToys-")
    }

    /// What's found going through one item: when anything in it was last used, the space it
    /// takes, whether something in it has to stay, and the parts of it that can go.
    struct Found {
        var newest: TimeInterval
        var size: Int64
        var kept: Bool
        var parts: [(path: String, size: Int64)]
    }

    /// Goes through `path`, on the disk `device`. `cutoff`, seconds since 1970, is when a part
    /// has to have been last used before to go; nil takes everything that may go.
    static func walk(_ path: String, device: dev_t, before cutoff: TimeInterval?) -> Found {
        var info = stat()
        guard !Task.isCancelled, lstat(path, &info) == 0 else { return Found(newest: .infinity, size: 0, kept: true, parts: []) }
        // Changed is when anything about it last changed on this Mac, which unpacking or copying
        // can't set: a file unpacked today with the date it had in its archive is new.
        let modified = max(TimeInterval(info.st_mtimespec.tv_sec), TimeInterval(info.st_ctimespec.tv_sec))
        var found = Found(newest: modified, size: Int64(info.st_blocks) * 512, kept: false, parts: [])
        // Another user's, or on another disk: not this cleaner's to delete, nor to look into.
        // Nor is anything macOS marks as its own, such as the folders its background services
        // keep in the person's temporary folder: what's in one can be deleted, but is theirs.
        guard info.st_uid == getuid(), info.st_dev == device, !isMarked(flags: info.st_flags), !isProtectedBySystem(path) else {
            found.kept = true
            return found
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            // A file read lately is in use as much as one written. Folders go by when they last
            // changed, as listing one counts as reading it.
            found.newest = max(modified, TimeInterval(info.st_atimespec.tv_sec))
        case S_IFLNK:
            break
        case S_IFDIR:
            // A folder that can't be changed can't have anything in it deleted.
            guard access(path, W_OK) == 0, let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                found.kept = true
                return found
            }
            var parts: [(path: String, size: Int64)] = []
            for name in names {
                let inner = walk(path + "/" + name, device: device, before: cutoff)
                found.newest = max(found.newest, inner.newest)
                found.size += inner.size
                found.kept = found.kept || inner.kept
                parts += inner.parts
            }
            guard !found.kept, cutoff.map({ found.newest < $0 }) ?? true else {
                found.parts = parts
                return found
            }
        default:
            // A socket or pipe, how a running app is reached, or a device.
            found.kept = true
            return found
        }
        if !found.kept, cutoff.map({ found.newest < $0 }) ?? true { found.parts = [(path, found.size)] }
        return found
    }

    /// Whether file flags say an item mustn't be deleted or changed: macOS's "can't be
    /// unlinked" and "restricted", which it sets on its own, or locked by its owner.
    static func isMarked(flags: UInt32) -> Bool {
        flags & UInt32(SF_NOUNLINK | SF_RESTRICTED | SF_IMMUTABLE | SF_APPEND | UF_IMMUTABLE | UF_APPEND) != 0
    }

    /// Whether System Integrity Protection covers an item, which macOS says with an attribute.
    private static func isProtectedBySystem(_ path: String) -> Bool {
        getxattr(path, "com.apple.rootless", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// What's in the temporary folders that can go, an item for each thing in them: the whole
    /// of it, or, when something in it has to stay, the parts of it that can go, together.
    static func scan(context: Cleanup.Context) -> CleanupScan {
        let mounts = Cleanup.mountPaths()
        var items: [CleanupItem] = []
        for root in context.temporaryFolders {
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
            else { continue }
            for name in names.sorted() where !protects(name) {
                if Task.isCancelled { break }
                let path = root.path + "/" + name
                let found = parts(of: path, device: info.st_dev, context: context, mounts: mounts)
                guard !found.parts.isEmpty else { continue }
                let whole = found.parts.count == 1 && found.parts[0].path == path
                items.append(
                    CleanupItem(
                        id: path, name: whole ? name : "\(name) (part of it)", url: URL(filePath: path),
                        size: found.parts.reduce(0) { $0 + $1.size }, skipReason: found.reason))
            }
        }
        return CleanupScan(items: items.sorted { $0.size > $1.size })
    }

    /// The parts of an item in a temporary folder that can go now, or, with why, the parts that
    /// would have if nothing kept them. Nothing is listed when nothing in it would go.
    static func parts(
        of path: String, device: dev_t, context: Cleanup.Context, mounts: [String]
    ) -> (parts: [(path: String, size: Int64)], reason: String?) {
        let found = walk(path, device: device, before: context.temporaryCutoff).parts
        guard !found.isEmpty else { return ([], nil) }
        // An app keeps a folder named for it while it runs, with nothing open in it at times.
        switch context.activity.ownerIsRunning(URL(filePath: path).lastPathComponent) {
        case true?: return (found, "App is open")
        case nil: return (found, Cleanup.unknownUse)
        case false?: break
        }
        var going: [(path: String, size: Int64)] = []
        var reason: String?
        for part in found {
            switch context.activity.isOpen(path: part.path) {
            case true?:
                reason = reason ?? "In use"
                continue
            case nil: return (found, Cleanup.unknownUse)
            case false?: break
            }
            if Cleanup.hasMount(inside: URL(filePath: part.path), mounts: mounts) {
                reason = reason ?? "Another disk is inside"
                continue
            }
            going.append(part)
        }
        if going.isEmpty { return (found, reason) }
        return (going, nil)
    }

    /// The same for a listed item, looked at again right before it's deleted: something may
    /// have been put in it since, a socket for one, which stays, or been opened.
    static func partsNow(of item: URL, context: Cleanup.Context) -> (parts: [(path: String, size: Int64)], reason: String?) {
        guard let root = context.temporaryFolders.first(where: { item.path.hasPrefix($0.path + "/") }) else {
            return ([], "Outside the temporary folders")
        }
        var info = stat()
        guard lstat(root.path, &info) == 0 else { return ([], "Outside the temporary folders") }
        return parts(of: item.path, device: info.st_dev, context: context, mounts: Cleanup.mountPaths())
    }

    /// Why an item mustn't be deleted: it isn't in a temporary folder, or a folder between them
    /// is a symbolic link that could send the cleanup somewhere else.
    static func reason(toKeep item: URL, roots: [URL]) -> String? {
        let path = item.path
        guard !item.pathComponents.contains(".."),
            let root = roots.first(where: { path.hasPrefix($0.path + "/") })
        else { return "Outside the temporary folders" }
        var folder = item.deletingLastPathComponent()
        while folder.path.count >= root.path.count {
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return "Linked elsewhere" }
            folder.deleteLastPathComponent()
        }
        return nil
    }
}
