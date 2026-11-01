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
        return resourceCandidates
            .map { $0.appendingPathComponent("libSofaSplitHook.dylib") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var bundledHandlers: URL? {
        let candidates = resourceCandidates.map { $0.appendingPathComponent("Handlers") }
            + [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Handlers")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Creates the data folders and installs bundled handlers that the user doesn't have yet.
    public static func bootstrap() {
        let fm = FileManager.default
        for dir in [root, handlers, content] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let bundled = bundledHandlers,
              let files = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "js" {
            let dest = handlers.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: file, to: dest) }
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
