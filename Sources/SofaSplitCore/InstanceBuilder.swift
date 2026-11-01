import Foundation

public struct PreparedInstance {
    public var root: URL
    public var appURL: URL?
    public var executableURL: URL
    public var workingDirectory: URL
    public var homeURL: URL?
    public var bundleIdentifier: String?
}

/// Builds one isolated copy of the game per player — the macOS counterpart of Nucleus Co-op's symlinked instance folders.
/// Copies are APFS clones, so they take no extra disk space until a file changes.
public enum InstanceBuilder {
    public static func prepare(handler: GameHandler, source: URL, index: Int, inject: Bool) throws -> PreparedInstance {
        let fm = FileManager.default
        let root = Paths.content.appendingPathComponent(handler.guid).appendingPathComponent("Instance\(index)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let isBundle = source.pathExtension == "app"
        let cloneGame = handler.bool("CloneGame", default: true)
        let changeBundleID = handler.bool("ChangeBundleID", default: true)

        var appURL: URL? = isBundle ? source : nil
        var bundleID = isBundle ? Bundle(url: source)?.bundleIdentifier : nil

        if isBundle && cloneGame {
            let dest = root.appendingPathComponent(source.lastPathComponent)
            let marker = root.appendingPathComponent(".sofasplit-source")
            let fingerprint = try fingerprint(source: source, handler: handler, inject: inject)
            if (try? String(contentsOf: marker, encoding: .utf8)) == fingerprint, fm.fileExists(atPath: dest.path) {
                log("P\(index + 1): reusing instance at \(dest.path)")
            } else {
                log("P\(index + 1): cloning \(source.lastPathComponent)…")
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: source, to: dest)  // clonefile() on APFS
                try customize(bundle: dest, handler: handler, index: index, changeBundleID: changeBundleID, inject: inject)
                try fingerprint.write(to: marker, atomically: true, encoding: .utf8)
            }
            appURL = dest
            bundleID = readBundleID(dest) ?? bundleID
        }

        guard let executable = isBundle ? executableURL(of: appURL!) : source else {
            throw NSError(domain: "SofaSplit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot find the executable inside \(source.path)"])
        }

        var home: URL?
        if handler.bool("IsolateHome", default: false) {
            let h = root.appendingPathComponent("home")
            for sub in ["Documents", "Library/Application Support", "Library/Preferences", "Library/Caches"] {
                try fm.createDirectory(at: h.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            home = h
            let realHome = fm.homeDirectoryForCurrentUser
            // Shared with the real home (e.g. the Steam client's folder, so steam_api still finds it).
            for rel in handler.strings("HomeSymlinks") {
                let link = h.appendingPathComponent(rel)
                guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil else { continue }
                try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: realHome.appendingPathComponent(rel))
            }
            // Seeded once from the real home (e.g. saves/settings), then each player keeps their own copy.
            for rel in handler.strings("HomeCopies") {
                let dest = h.appendingPathComponent(rel)
                let src = realHome.appendingPathComponent(rel)
                guard !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: src.path) else { continue }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dest)
            }
        }

        var workDir = executable.deletingLastPathComponent()
        if let wf = handler.string("WorkingFolder"), !wf.isEmpty {
            workDir = (appURL ?? source.deletingLastPathComponent()).appendingPathComponent(wf)
        }
        // Only write into our clones, never into the user's original install.
        if let steamID = handler.string("SteamID"), !steamID.isEmpty, appURL != nil, appURL != source {
            // steam_api looks in the working directory; Unity games also next to the .app.
            for dir in [workDir, appURL!.deletingLastPathComponent()] {
                try? steamID.write(to: dir.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)
            }
        }

        return PreparedInstance(root: root, appURL: appURL, executableURL: executable, workingDirectory: workDir,
                                homeURL: home, bundleIdentifier: bundleID)
    }

    static func executableURL(of app: URL) -> URL? {
        if let exe = Bundle(url: app)?.executableURL { return exe }
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let name = plist?["CFBundleExecutable"] as? String else { return nil }
        return app.appendingPathComponent("Contents/MacOS/\(name)")
    }

    static func readBundleID(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    private static func fingerprint(source: URL, handler: GameHandler, inject: Bool) throws -> String {
        let attrs = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0 }
        let exe = executableURL(of: source) ?? source
        return ["v2", source.path, "\(attrs(exe))", "\(attrs(handler.url))", "inject=\(inject)"].joined(separator: "|")
    }

    private static func customize(bundle: URL, handler: GameHandler, index: Int, changeBundleID: Bool, inject: Bool) throws {
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")

        if changeBundleID, let info = NSMutableDictionary(contentsOf: infoURL), let bid = info["CFBundleIdentifier"] as? String {
            // A unique id per instance stops single-instance checks and separates each player's preferences.
            // Launching the executable directly doesn't enforce the Info.plist seal, so no re-sign is needed.
            info["CFBundleIdentifier"] = "\(bid).sofasplit\(index + 1)"
            try info.write(to: infoURL)
        }

        let handlerDir = handler.url.deletingLastPathComponent()
        for entry in handler.strings("CopyFiles") {
            // "source/in/handlers/folder -> Contents/MacOS/dest"
            let parts = entry.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let to = bundle.appendingPathComponent(parts[1])
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: handlerDir.appendingPathComponent(parts[0]), to: to)
            // Replaced binaries need a valid signature of their own to be loaded on Apple Silicon.
            run("/usr/bin/codesign", ["--force", "--sign", "-", to.path])
        }
        for rel in handler.strings("DeleteFiles") {
            try? FileManager.default.removeItem(at: bundle.appendingPathComponent(rel))
        }

        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundle.path])

        // Hardened runtime / library validation make dyld ignore DYLD_INSERT_LIBRARIES,
        // so such clones get a local ad-hoc signature without them.
        if inject && signatureBlocksInjection(bundle) {
            log("Re-signing \(bundle.lastPathComponent) ad-hoc so the hook can load (this can take a while for big games)…")
            if run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", bundle.path]) != 0 {
                log("Deep signing failed, retrying top-level only")
                run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
            }
        }
    }

    static func signatureBlocksInjection(_ bundle: URL) -> Bool {
        let out = capture("/usr/bin/codesign", ["-dv", "--verbose=2", bundle.path])
        guard let flagsLine = out.split(separator: "\n").first(where: { $0.contains("flags=") }) else { return false }
        return flagsLine.contains("runtime") || flagsLine.contains("library-validation")
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func capture(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
