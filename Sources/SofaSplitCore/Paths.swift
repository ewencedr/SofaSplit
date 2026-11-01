import Foundation

public enum Paths {
    public static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SofaSplit", isDirectory: true)
    }()

    public static var handlers: URL { root.appendingPathComponent("handlers", isDirectory: true) }
    public static var content: URL { root.appendingPathComponent("content", isDirectory: true) }
    public static var libraryFile: URL { root.appendingPathComponent("library.json") }
    public static var logFile: URL { root.appendingPathComponent("sofasplit.log") }

    /// Directories next to the running binary where bundled resources may live
    /// (inside the .app: Contents/Resources; in a dev checkout: build/).
    static var resourceCandidates: [URL] {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var dirs = [exe.appendingPathComponent("../Resources").standardizedFileURL, exe]
        if let r = Bundle.main.resourceURL { dirs.insert(r, at: 0) }
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build"))
        return dirs
    }

    public static var hookLibrary: URL? {
        if let p = ProcessInfo.processInfo.environment["SOFASPLIT_HOOK_PATH"] { return URL(fileURLWithPath: p) }
        guard let bundled = resourceCandidates
            .map({ $0.appendingPathComponent("libSofaSplitHook.dylib") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return installedHook(from: bundled) ?? bundled
    }

    /// Copies the hook out of the app into the data folder and clears its quarantine flag. A downloaded app
    /// is quarantined (and may run from a randomized read-only path), and a quarantined library injected
    /// into a game would trigger Gatekeeper inside the game.
    static func installedHook(from bundled: URL) -> URL? {
        let fm = FileManager.default
        let dest = root.appendingPathComponent("lib/libSofaSplitHook.dylib")
        func attrs(_ u: URL) -> (Int, Date)? {
            guard let a = try? fm.attributesOfItem(atPath: u.path) else { return nil }
            return ((a[.size] as? Int) ?? 0, (a[.modificationDate] as? Date) ?? .distantPast)
        }
        if let src = attrs(bundled), let cur = attrs(dest), src.0 == cur.0, cur.1 >= src.1 { return dest }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: bundled, to: dest)
            removexattr(dest.path, "com.apple.quarantine", 0)
            return dest
        } catch {
            return nil
        }
    }

    public static var bundledHandlers: URL? {
        let candidates = resourceCandidates.map { $0.appendingPathComponent("Handlers") }
            + [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Handlers")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Creates the data folders and keeps a reference copy of the handler template in the user's handlers folder.
    /// Bundled handlers are read from the app itself, so updates reach users; files in the folder override them.
    public static func bootstrap() {
        let fm = FileManager.default
        for dir in [root, handlers, content] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Old game copies left behind if the app quit while deleting them.
        let trash = content.appendingPathComponent(".trash")
        DispatchQueue.global(qos: .background).async { try? fm.removeItem(at: trash) }
        if let template = bundledHandlers?.appendingPathComponent("_Template.js"), fm.fileExists(atPath: template.path) {
            let dest = handlers.appendingPathComponent("_Template.js")
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: template, to: dest)
        }
    }
}

public final class Log {
    public static let shared = Log()
    public var sink: ((String) -> Void)?
    private let queue = DispatchQueue(label: "sofasplit.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public func callAsFunction(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        queue.async {
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
            if let h = try? FileHandle(forWritingTo: Paths.logFile) {
                h.seekToEndOfFile()
                h.write((line + "\n").data(using: .utf8)!)
                try? h.close()
            } else {
                try? (line + "\n").write(to: Paths.logFile, atomically: false, encoding: .utf8)
            }
        }
        if let sink {
            DispatchQueue.main.async { sink(line) }
        }
    }
}

public let log = Log.shared
