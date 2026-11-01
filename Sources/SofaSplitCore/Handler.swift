import Foundation
import JavaScriptCore

public enum HandlerError: LocalizedError {
    case script(String)
    public var errorDescription: String? {
        switch self { case .script(let m): return "Handler script error: \(m)" }
    }
}

/// Values handed to Game.Play() for one instance.
public struct PlayContext {
    public var playerIndex: Int
    public var playerCount: Int
    public var frame: CGRect
    public var scale: CGFloat
    public var instanceRoot: URL
    public var appURL: URL?
    public var homeURL: URL?
    public var bundleIdentifier: String?
    public var startArguments: String
    public var environment: [String: String]
    public var assignment: Assignment
}

/// A game handler: a JavaScript file in the same spirit as Nucleus Co-op handlers.
/// See Handlers/_Template.js for every supported option.
public final class GameHandler {
    public let url: URL
    private let context: JSContext
    private let game: JSValue

    private static let prelude = """
    var Game = { Hook: {} };
    var SofaSplit = { Folder: { Home: "Home", Documents: "Documents", AppSupport: "AppSupport",
                              Preferences: "Preferences", Caches: "Caches", Instance: "Instance",
                              InstanceRoot: "InstanceRoot", InstanceHome: "InstanceHome", Handler: "Handler" } };
    var console = { log: function () { __sofasplitLog(Array.prototype.join.call(arguments, " ")); } };
    """

    public init(url: URL) throws {
        self.url = url
        let source = try String(contentsOf: url, encoding: .utf8)
        context = JSContext()!
        let name = url.lastPathComponent
        let logBlock: @convention(block) (String) -> Void = { log("[\(name)] \($0)") }
        context.setObject(unsafeBitCast(logBlock, to: AnyObject.self), forKeyedSubscript: "__sofasplitLog" as NSString)
        context.evaluateScript(Self.prelude)
        context.evaluateScript(source, withSourceURL: url)
        if let ex = context.exception {
            throw HandlerError.script("\(name): \(ex.toString() ?? "?") (line \(ex.forProperty("line")?.toString() ?? "?"))")
        }
        game = context.objectForKeyedSubscript("Game")
    }

    // MARK: Property access

    func value(_ path: String) -> JSValue? {
        var v: JSValue? = game
        for part in path.split(separator: ".") { v = v?.forProperty(String(part)) }
        guard let v, !v.isUndefined, !v.isNull else { return nil }
        return v
    }

    public func string(_ path: String) -> String? { value(path)?.toString() }
    public func bool(_ path: String, default d: Bool) -> Bool { value(path)?.toBool() ?? d }
    public func int(_ path: String, default d: Int) -> Int { value(path).map { Int($0.toInt32()) } ?? d }
    public func strings(_ path: String) -> [String] { (value(path)?.toArray() ?? []).map { "\($0)" } }
    public func dictionary(_ path: String) -> [String: String] {
        (value(path)?.toDictionary() ?? [:]).reduce(into: [:]) { $0["\($1.key)"] = "\($1.value)" }
    }

    public var gameName: String { string("GameName") ?? url.deletingPathExtension().lastPathComponent }
    public var guid: String {
        let raw = string("GUID") ?? gameName
        return raw.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    public var executableName: String? { string("ExecutableName") }
    public var bundleIdentifier: String? { string("BundleIdentifier") }
    public var maxPlayers: Int { int("MaxPlayers", default: 8) }
    public var notes: String? { string("Description") }
    public var isGeneric: Bool { executableName == nil && bundleIdentifier == nil }

    /// Does this handler describe the given app or executable?
    public func matches(_ app: URL) -> Bool {
        if let exe = executableName?.lowercased() {
            if app.lastPathComponent.lowercased() == exe { return true }
            if let bundleExe = Bundle(url: app)?.executableURL?.lastPathComponent.lowercased(), bundleExe == exe { return true }
        }
        if let bid = bundleIdentifier, Bundle(url: app)?.bundleIdentifier == bid { return true }
        return false
    }

    // MARK: Game.Play

    /// Runs Game.Play(Context) for one instance; returns the (possibly modified) arguments and environment.
    public func runPlay(_ ctx: PlayContext) throws -> (arguments: String, environment: [String: String]) {
        guard let play = value("Play"), play.isObject else { return (ctx.startArguments, ctx.environment) }
        let obj = JSValue(newObjectIn: context)!
        let set: (String, Any?) -> Void = { obj.setValue($1 ?? NSNull(), forProperty: $0) }
        set("PlayerID", ctx.playerIndex)
        set("PlayerNumber", ctx.playerIndex + 1)
        set("PlayersCount", ctx.playerCount)
        set("Width", Int(ctx.frame.width))
        set("Height", Int(ctx.frame.height))
        set("PixelWidth", Int(ctx.frame.width * ctx.scale))
        set("PixelHeight", Int(ctx.frame.height * ctx.scale))
        set("PosX", Int(ctx.frame.minX))
        set("PosY", Int(ctx.frame.minY))
        set("InstanceRoot", ctx.instanceRoot.path)
        set("InstanceFolder", ctx.appURL?.path)
        set("HomeFolder", (ctx.homeURL ?? FileManager.default.homeDirectoryForCurrentUser).path)
        set("BundleIdentifier", ctx.bundleIdentifier)
        set("StartArguments", ctx.startArguments)
        set("Environment", ctx.environment)
        set("IsKeyboardPlayer", ctx.assignment == .keyboardMouse)
        installAPI(on: obj, ctx: ctx)

        context.setObject(obj, forKeyedSubscript: "Context" as NSString)
        play.call(withArguments: [obj])
        if let ex = context.exception {
            context.exception = nil
            throw HandlerError.script("Game.Play: \(ex.toString() ?? "?") (line \(ex.forProperty("line")?.toString() ?? "?"))")
        }
        let args = obj.forProperty("StartArguments")?.toString() ?? ctx.startArguments
        let env = (obj.forProperty("Environment")?.toDictionary() ?? [:])
            .reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        return (args, env)
    }

    private func installAPI(on obj: JSValue, ctx: PlayContext) {
        let handlerDir = url.deletingLastPathComponent()
        let home = ctx.homeURL ?? FileManager.default.homeDirectoryForCurrentUser

        func resolve(_ p: String) -> URL {
            let expanded = (p as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
            return ctx.instanceRoot.appendingPathComponent(expanded)
        }
        func fn(_ name: String, _ body: @escaping ([JSValue]) throws -> Any?) {
            let block: @convention(block) () -> Any? = {
                let args = (JSContext.currentArguments() as? [JSValue]) ?? []
                do { return try body(args) } catch {
                    JSContext.current()?.exception = JSValue(newErrorFromMessage: "\(name): \(error.localizedDescription)",
                                                             in: JSContext.current())
                    return nil
                }
            }
            obj.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: name as NSString)
        }
        func arg(_ a: [JSValue], _ i: Int) -> String { i < a.count ? (a[i].toString() ?? "") : "" }

        fn("Log") { a in log("[\(self.gameName) P\(ctx.playerIndex + 1)] \(a.map { $0.toString() ?? "" }.joined(separator: " "))"); return nil }
        fn("GetFolder") { a in
            switch arg(a, 0) {
            case "Home": return home.path
            case "Documents": return home.appendingPathComponent("Documents").path
            case "AppSupport": return home.appendingPathComponent("Library/Application Support").path
            case "Preferences": return home.appendingPathComponent("Library/Preferences").path
            case "Caches": return home.appendingPathComponent("Library/Caches").path
            case "Instance": return ctx.appURL?.path ?? ctx.instanceRoot.path
            case "InstanceRoot": return ctx.instanceRoot.path
            case "InstanceHome": return home.path
            case "Handler": return handlerDir.path
            default: return home.path
            }
        }
        fn("FileExists") { a in FileManager.default.fileExists(atPath: resolve(arg(a, 0)).path) }
        fn("ReadFile") { a in try String(contentsOf: resolve(arg(a, 0)), encoding: .utf8) }
        fn("WriteFile") { a in
            let u = resolve(arg(a, 0))
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try arg(a, 1).write(to: u, atomically: true, encoding: .utf8)
            return true
        }
        fn("MakeDir") { a in try FileManager.default.createDirectory(at: resolve(arg(a, 0)), withIntermediateDirectories: true); return true }
        fn("DeleteFile") { a in try? FileManager.default.removeItem(at: resolve(arg(a, 0))); return true }
        fn("CopyFile") { a in
            let from = arg(a, 0).hasPrefix("/") ? resolve(arg(a, 0)) : handlerDir.appendingPathComponent(arg(a, 0))
            let to = resolve(arg(a, 1))
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: from, to: to)
            return true
        }
        // ReplaceInFile(path, regex, replacement)
        fn("ReplaceInFile") { a in
            let u = resolve(arg(a, 0))
            let text = try String(contentsOf: u, encoding: .utf8)
            let re = try NSRegularExpression(pattern: arg(a, 1), options: [.anchorsMatchLines])
            let out = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: arg(a, 2))
            try out.write(to: u, atomically: true, encoding: .utf8)
            return out != text
        }
        // ModifyIni(path, section, key, value)
        fn("ModifyIni") { a in
            let u = resolve(arg(a, 0))
            let text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            let out = IniFile.set(text, section: arg(a, 1), key: arg(a, 2), value: arg(a, 3))
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: u, atomically: true, encoding: .utf8)
            return true
        }
        // SetPlistValue(path, "Key.Sub", value) — creates the plist if needed.
        fn("SetPlistValue") { a in
            guard a.count >= 3 else { return false }
            try PlistFile.set(at: resolve(arg(a, 0)), keyPath: arg(a, 1), value: a[2].toObject() as Any)
            return true
        }
        // ModifyJson(path, "key.sub", value) — e.g. a Unity game's own settings file.
        fn("ModifyJson") { a in
            guard a.count >= 3 else { return false }
            try JsonFile.set(at: resolve(arg(a, 0)), keyPath: arg(a, 1), value: a[2].toObject() as Any)
            return true
        }
        // SetDefault(key, value) — writes into this instance's preferences domain (its bundle id).
        // Goes through cfprefsd, which ignores CFFIXED_USER_HOME, so this works with IsolateHome too.
        fn("SetDefault") { a in
            guard a.count >= 2, let bid = ctx.bundleIdentifier else { return false }
            CFPreferencesSetAppValue(arg(a, 0) as CFString, a[1].toObject() as CFPropertyList, bid as CFString)
            CFPreferencesAppSynchronize(bid as CFString)
            return true
        }
    }
}

enum IniFile {
    static func set(_ text: String, section: String, key: String, value: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var inSection = section.isEmpty
        var sectionEnd: Int? = section.isEmpty ? lines.count : nil
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if inSection { sectionEnd = i; break }
                inSection = line.dropFirst().dropLast().caseInsensitiveCompare(section) == .orderedSame
                if inSection { sectionEnd = lines.count }
                continue
            }
            if inSection, let eq = line.firstIndex(of: "="),
               line[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame {
                lines[i] = "\(key)=\(value)"
                return lines.joined(separator: "\n")
            }
        }
        if let end = sectionEnd {
            var insertAt = end
            while insertAt > 0 && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            lines.insert("\(key)=\(value)", at: insertAt)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append(contentsOf: ["[\(section)]", "\(key)=\(value)"])
        }
        return lines.joined(separator: "\n")
    }
}

enum PlistFile {
    static func set(at url: URL, keyPath: String, value: Any) throws {
        var root: [String: Any] = [:]
        var format = PropertyListSerialization.PropertyListFormat.binary
        if let data = try? Data(contentsOf: url),
           let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] {
            root = dict
        }
        assignKeyPath(&root, keyPath, value)
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

enum JsonFile {
    static func set(at url: URL, keyPath: String, value: Any) throws {
        var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        assignKeyPath(&root, keyPath, value)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

/// Sets "a.b.c" inside nested dictionaries, creating intermediate levels.
func assignKeyPath(_ dict: inout [String: Any], _ keyPath: String, _ value: Any) {
    func assign(_ dict: inout [String: Any], _ keys: ArraySlice<Substring>) {
        guard let first = keys.first else { return }
        if keys.count == 1 { dict[String(first)] = value; return }
        var child = dict[String(first)] as? [String: Any] ?? [:]
        assign(&child, keys.dropFirst())
        dict[String(first)] = child
    }
    assign(&dict, keyPath.split(separator: ".")[...])
}

public enum HandlerStore {
    public static func all() -> [GameHandler] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.handlers, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "js" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                do { return try GameHandler(url: url) } catch { log("Skipping handler: \(error.localizedDescription)"); return nil }
            }
    }

    /// Picks the handler written for this app, falling back to Generic.js.
    public static func bestMatch(for app: URL) -> GameHandler? {
        let handlers = all()
        return handlers.first { $0.matches(app) }
            ?? handlers.first { $0.url.lastPathComponent == "Generic.js" }
            ?? handlers.first { $0.isGeneric }
    }
}
