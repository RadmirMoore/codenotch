import Foundation
import Darwin

/// A single actor owns incremental offsets; overlapping refreshes cannot
/// double-count. No database, network, credential API, or subprocess is used.
public actor LogScanner {
    private struct FileState {
        var inode: UInt64
        var device: Int32
        var offset: UInt64 = 0
        var modified: Int64
        var parser = RolloutParser()
    }
    private var states: [String: FileState] = [:]
    public init() {}

    public func clear() { states.removeAll() }

    public func scan(roots: [URL], now: Date = Date(), calendar: Calendar = .current,
                     byteBudget: Int = 32 * 1024 * 1024) -> CounterSnapshot {
        var result = CounterSnapshot()
        var seenFiles = Set<String>()
        var remaining = byteBudget
        for selected in roots.sorted(by: { $0.path < $1.path }) {
            guard ["sessions", "archived_sessions"].contains(selected.lastPathComponent),
                  let rootValues = try? selected.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  rootValues.isSymbolicLink != true else {
                result.skipped += 1; continue
            }
            let rootFD = open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { result.skipped += 1; continue }
            defer { close(rootFD) }
            // Foundation's resolvingSymlinksInPath keeps special /var aliases,
            // whereas enumeration returns /private/var. Ask the opened descriptor
            // for its actual path so the traversal and prefix check agree.
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(rootFD, F_GETPATH, &pathBuffer) == 0 else { result.skipped += 1; continue }
            let canonical = String(cString: pathBuffer)
            let root = URL(fileURLWithPath: canonical, isDirectory: true)
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                errorHandler: { _, _ in result.skipped += 1; return true }) else {
                result.skipped += 1; continue
            }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    result.skipped += 1; continue
                }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants(); result.skipped += 1; continue
                }
                guard values.isRegularFile == true,
                      url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
                let prefix = canonical.hasSuffix("/") ? canonical : canonical + "/"
                guard url.path.hasPrefix(prefix) else { result.skipped += 1; continue }
                let relative = String(url.path.dropFirst(prefix.count))
                // openat + O_NOFOLLOW on EVERY component prevents a symlink swap
                // between directory enumeration and opening a file.
                guard let fd = Self.openFile(relative: relative, under: rootFD) else {
                    result.skipped += 1; continue
                }
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_nlink == 1, info.st_size >= 0 else {
                    result.skipped += 1; continue
                }
                let path = url.path
                seenFiles.insert(path)
                let size = UInt64(info.st_size)
                let stamp = Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec)
                var state = states[path] ?? FileState(inode: info.st_ino, device: info.st_dev, modified: stamp)
                if state.inode != info.st_ino || state.device != info.st_dev || size < state.offset
                    || (size == state.offset && stamp != state.modified) {
                    state = FileState(inode: info.st_ino, device: info.st_dev, modified: stamp)
                }
                state.modified = stamp
                if lseek(fd, off_t(state.offset), SEEK_SET) < 0 { result.skipped += 1; continue }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while state.offset < size && remaining > 0 {
                    let count = min(buffer.count, remaining, Int(min(size - state.offset, UInt64(buffer.count))))
                    let n = read(fd, &buffer, count)
                    if n <= 0 { if n < 0 { result.skipped += 1 }; break }
                    state.parser.feed(Data(buffer.prefix(n)))
                    state.offset += UInt64(n)
                    remaining -= n
                }
                if state.offset < size { result.catchingUp = true }
                states[path] = state
            }
        }
        // Removing access or deleting a log removes its contribution too.
        states = states.filter { seenFiles.contains($0.key) }
        result.files = states.count
        let today = calendar.startOfDay(for: now)
        let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var counted = Set<Data>()
        for path in states.keys.sorted() {
            guard let state = states[path] else { continue }
            result.skipped += state.parser.malformed
            result.resets += state.parser.resets
            for entry in state.parser.entries {
                guard entry.date <= now, counted.insert(entry.id).inserted else { continue }
                result.events += 1
                result.all.add(entry.tokens)
                if entry.date >= week { result.week.add(entry.tokens) }
                if entry.date >= today { result.today.add(entry.tokens) }
                if result.lastEvent == nil || entry.date > result.lastEvent! { result.lastEvent = entry.date }
            }
        }
        return result
    }

    private static func openFile(relative: String, under root: Int32) -> Int32? {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        var parent = dup(root)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        for part in parts.dropLast() {
            let child = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return nil }
            close(parent); parent = child
        }
        let file = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        return file >= 0 ? file : nil
    }
}
