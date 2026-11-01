import Foundation

public struct GameEntry: Identifiable, Codable, Hashable {
    public var id = UUID()
    public var name: String
    public var appPath: String
    public var handlerFile: String

    public var appURL: URL { URL(fileURLWithPath: appPath) }
    public var handlerURL: URL { Paths.handlers.appendingPathComponent(handlerFile) }
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

    @discardableResult
    public func add(app: URL) -> GameEntry? {
        guard let handler = HandlerStore.bestMatch(for: app) else {
            log("No handlers installed (expected Generic.js in \(Paths.handlers.path))")
            return nil
        }
        let name = handler.isGeneric
            ? (Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? app.deletingPathExtension().lastPathComponent)
            : handler.gameName
        let entry = GameEntry(name: name, appPath: app.path, handlerFile: handler.url.lastPathComponent)
        games.append(entry)
        log("Added \(name) using handler \(entry.handlerFile)")
        return entry
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(games).write(to: Paths.libraryFile)
    }
}
