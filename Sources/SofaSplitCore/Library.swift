import Foundation

public struct GameEntry: Identifiable, Codable, Hashable {
    public var id = UUID()
    public var name: String
    public var appPath: String
    public var handlerFile: String
    /// Settings changed in the app; they override the handler's options.
    public var options: [String: OptionValue]?
    /// What the analyzer found when the game was added.
    public var profile: GameProfile?

    public init(name: String, appPath: String, handlerFile: String, options: [String: OptionValue]? = nil,
                profile: GameProfile? = nil) {
        self.name = name
        self.appPath = appPath
        self.handlerFile = handlerFile
        self.options = options
        self.profile = profile
    }

    public var appURL: URL { URL(fileURLWithPath: appPath) }
    public var handlerURL: URL { HandlerStore.url(for: handlerFile) }
}

/// The user's list of added games, stored as JSON in Application Support.
public final class GameLibrary: ObservableObject {
    @Published public var games: [GameEntry] = [] { didSet { save() } }

    public init() {
        if let data = try? Data(contentsOf: Paths.libraryFile),
           let list = try? JSONDecoder().decode([GameEntry].self, from: data) {
            games = list
        }
    }

    /// Adds a game: picks its handler, analyzes it, and (for the generic handler) applies the settings that fit.
    /// Analysis reads the game's files, so call this off the main thread for big games.
    public static func makeEntry(app: URL, name preferredName: String? = nil) -> GameEntry? {
        guard let handler = HandlerStore.bestMatch(for: app) else {
            log("No handlers found (expected Generic.js inside the app)")
            return nil
        }
        let profile = GameAnalyzer.analyze(app)
        let name = handler.isGeneric
            ? (preferredName ?? profile.steamName
               ?? Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleName") as? String
               ?? app.deletingPathExtension().lastPathComponent)
            : handler.gameName
        var options: [String: OptionValue] = [:]
        if handler.isGeneric {
            options = profile.suggestedOptions
            options["GUID"] = .string(name)  // own instance folder per game
        }
        let verdict = profile.assessment
        log("Added \(name) using \(handler.url.lastPathComponent) — \(verdict.verdict.rawValue): \(verdict.reasons.joined(separator: " "))")
        return GameEntry(name: name, appPath: app.path, handlerFile: handler.url.lastPathComponent,
                         options: options.isEmpty ? nil : options, profile: profile)
    }

    /// The game's handler with the app's settings applied.
    public static func handler(for entry: GameEntry) throws -> GameHandler {
        let h = try GameHandler(url: entry.handlerURL)
        h.overrides = entry.options ?? [:]
        return h
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(games).write(to: Paths.libraryFile)
    }
}
