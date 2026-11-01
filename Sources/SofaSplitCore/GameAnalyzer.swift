import Foundation

/// What SofaSplit can tell about a game from its files, used to pick settings and to tell
/// the user up front whether split-screen co-op is likely to work.
public struct GameProfile: Codable, Hashable {
    public enum Engine: String, Codable { case unity = "Unity", unreal = "Unreal", godot = "Godot", other = "Unknown" }
    public enum Verdict: String, Codable { case likely, maybe, unlikely }

    /// Bumped whenever the analyzer learns something new, so saved results get refreshed.
    public static let currentVersion = 2
    public var version = GameProfile.currentVersion
    public var engine: Engine = .other
    /// "Mono" or "IL2CPP" for Unity games.
    public var unityScripting: String?
    /// Unity's company/product names, which form the save folder (~/Library/Application Support/<company>/<product>).
    public var unityCompany: String?
    public var unityProduct: String?
    public var steamAppID: String?
    public var steamName: String?
    public var usesSteam = false
    /// The game reaches Steam through the flat C API resolved at runtime (C# games: Steamworks.NET,
    /// Facepunch.Steamworks, IL2CPP), which is what the multiplayer emulation intercepts.
    public var steamViaFlatAPI = false
    /// For IL2CPP the metadata also lists the Steam wrapper's own names, so feature detection is a guess.
    public var steamFeaturesCertain = true
    public var steamLobbies = false
    public var steamMessages = false
    public var steamSockets = false
    public var steamLegacyP2P = false
    public var steamInput = false
    /// The game requests a Steam login ticket, which an online service verifies with Steam's servers.
    /// Such a service sees the real account in every window, whatever SofaSplit reports to the game.
    public var steamAuthTicket = false
    /// Connects players through Photon (Exit Games' relay service) rather than Steam networking.
    public var photon = false
    public var hardenedRuntime = false
    public var appStore = false

    public init() {}

    /// A plain-language verdict plus the reasons behind it.
    public var assessment: (verdict: Verdict, reasons: [String]) {
        var reasons: [String] = []
        if appStore {
            return (.unlikely, ["Mac App Store games are encrypted, so SofaSplit can't run separate copies with their own controller."])
        }
        var verdict = Verdict.maybe
        let steamNetworking = steamMessages || steamLegacyP2P || steamSockets
        if photon && steamAuthTicket && !steamNetworking && steamFeaturesCertain {
            verdict = .unlikely
            reasons.append("Connects players through Photon, an online service that checks the Steam account. Every window is "
                           + "signed in to the same account, so the service turns the second player away.")
        } else if usesSteam && steamViaFlatAPI {
            if !steamFeaturesCertain {
                reasons.append("Couldn't tell which Steam features the game uses (its Steam library is built into the game). "
                               + "Try it; if the windows can't join each other, turn on Steam multiplayer in the game settings.")
            } else if steamLobbies && (steamMessages || steamLegacyP2P) {
                verdict = .likely
                reasons.append("Uses Steam lobbies and Steam networking: SofaSplit gives every window its own Steam identity so they can join each other.")
                if steamSockets {
                    reasons.append("It also contains Steam networking sockets, which SofaSplit can't emulate yet; if joining fails, check the game's network options.")
                }
            } else if steamSockets {
                verdict = .unlikely
                reasons.append("Uses Steam networking sockets for multiplayer, which SofaSplit can't emulate yet. LAN or direct IP still work if the game has them.")
            } else if steamLegacyP2P || steamMessages {
                reasons.append("Uses Steam networking without Steam lobbies: works if the game connects players by Steam ID or through LAN.")
            } else if steamLobbies {
                reasons.append("Uses Steam lobbies; works if the game connects players through them or through LAN.")
            } else {
                reasons.append("No Steam multiplayer found: works if the game has LAN or direct-IP multiplayer.")
            }
        } else if usesSteam {
            reasons.append("Talks to Steam from native code, which SofaSplit can't give separate Steam identities: works only with LAN or direct-IP multiplayer.")
        } else {
            reasons.append("Works if the game has LAN or direct-IP multiplayer.")
        }
        if photon && steamAuthTicket && steamNetworking {
            reasons.append("Some features (such as voice chat or cross-play) go through Photon, an online service that checks the "
                           + "Steam account; those may not work between the windows.")
        } else if steamAuthTicket && !photon && verdict != .unlikely {
            reasons.append("Signs in to an online service with the Steam account. If that service refuses the same account twice, "
                           + "only LAN or direct IP will work.")
        }
        if steamInput { reasons.append("Reads controllers through Steam Input: each window gets its own controller.") }
        if hardenedRuntime { reasons.append("First launch of each player's copy takes longer: it has to be re-signed so the hook can load.") }
        return (verdict, reasons)
    }

    /// Handler options that fit this game, applied on top of the generic handler.
    public var suggestedOptions: [String: OptionValue] {
        var options: [String: OptionValue] = [:]
        if let steamAppID { options["SteamID"] = .string(steamAppID) }
        if steamInput { options["Hook.SteamInput"] = .bool(true) }
        if usesSteam && steamViaFlatAPI && steamFeaturesCertain && steamLobbies && (steamMessages || steamLegacyP2P) {
            options["Hook.SteamMultiplayer"] = .bool(true)
        }
        if engine == .unity, let company = unityCompany, let product = unityProduct {
            // Separate saves per player, seeded from the user's own, while still finding the Steam client.
            options["IsolateHome"] = .bool(true)
            options["HomeCopies"] = .strings(["Library/Application Support/\(company)/\(product)"])
            options["HomeSymlinks"] = .strings(["Library/Application Support/Steam"])
        }
        return options
    }
}

/// A handler option set from the app (overrides the handler's own value).
public enum OptionValue: Codable, Hashable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case strings([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .strings(try c.decode([String].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        case .strings(let a): try c.encode(a)
        }
    }

    var object: Any {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i
        case .string(let s): return s
        case .strings(let a): return a
        }
    }
}

public enum GameAnalyzer {
    public static func analyze(_ app: URL) -> GameProfile {
        var p = GameProfile()
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        let data = contents.appendingPathComponent("Resources/Data")

        p.appStore = fm.fileExists(atPath: contents.appendingPathComponent("_MASReceipt").path)
        p.hardenedRuntime = InstanceBuilder.signatureBlocksInjection(app)

        // Engine
        if fm.fileExists(atPath: contents.appendingPathComponent("Frameworks/UnityPlayer.dylib").path)
            || fm.fileExists(atPath: data.appendingPathComponent("globalgamemanagers").path) {
            p.engine = .unity
            p.unityScripting = fm.fileExists(atPath: data.appendingPathComponent("Managed").path) ? "Mono" : "IL2CPP"
            if let info = try? String(contentsOf: data.appendingPathComponent("app.info"), encoding: .utf8) {
                let lines = info.split(whereSeparator: \.isNewline).map(String.init)
                if lines.count >= 2 { p.unityCompany = lines[0]; p.unityProduct = lines[1] }
            }
        } else if bundleContains(app, where: { $0.hasSuffix(".pck") }) {
            p.engine = .godot
        } else if bundleContains(app, where: { $0.contains("UE4") || $0.contains("UnrealEngine") || $0 == "Engine" }) {
            p.engine = .unreal
        }

        // Steam
        (p.steamAppID, p.steamName) = SteamLibrary.appID(forGameAt: app)
        if p.steamAppID == nil,
           let id = try? String(contentsOf: contents.appendingPathComponent("MacOS/steam_appid.txt"), encoding: .utf8) {
            p.steamAppID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        p.usesSteam = bundleContains(app, where: { $0 == "libsteam_api.dylib" || $0 == "steam_api.bundle" })

        if p.usesSteam {
            let managed = data.appendingPathComponent("Managed")
            let metadata = data.appendingPathComponent("il2cpp_data/Metadata/global-metadata.dat")
            if fm.fileExists(atPath: managed.path) {
                analyzeManagedSteamUsage(managed, into: &p)
            } else if fm.fileExists(atPath: metadata.path) {
                analyzeIL2CPPSteamUsage(contents.appendingPathComponent("Frameworks/GameAssembly.dylib"), into: &p)
            }
        }
        let managed = data.appendingPathComponent("Managed")
        let metadata = data.appendingPathComponent("il2cpp_data/Metadata/global-metadata.dat")
        p.photon = fm.fileExists(atPath: managed.appendingPathComponent("Photon3Unity3D.dll").path)
            || !scan([metadata], for: ["Photon3Unity3D"]).isEmpty
        return p
    }

    /// C# (Mono) games. The Steam wrapper (Steamworks.NET, Facepunch, …) lists every Steam API, so it says nothing
    /// about what the game uses: it's recognised by the flat API entry names it P/Invokes ("SteamAPI_ISteam…"),
    /// and only the other assemblies count as evidence. If no assembly has those names, the game reaches Steam
    /// through a native plugin, which the emulation can't intercept.
    static func analyzeManagedSteamUsage(_ managed: URL, into p: inout GameProfile) {
        let systemPrefixes = ["UnityEngine", "Unity.", "System", "Mono.", "mscorlib", "netstandard", "Microsoft."]
        let assemblies = ((try? FileManager.default.contentsOfDirectory(at: managed, includingPropertiesForKeys: nil)) ?? [])
            .filter { f in f.pathExtension == "dll" && !systemPrefixes.contains { f.lastPathComponent.hasPrefix($0) } }
        let wrappers = assemblies.filter { !scan([$0], for: ["SteamAPI_ISteam"]).isEmpty }
        p.steamViaFlatAPI = !wrappers.isEmpty
        guard p.steamViaFlatAPI else { return }
        // A wrapper compiled into the game's own assembly (Assembly-CSharp-firstpass) hides what the game calls.
        p.steamFeaturesCertain = !wrappers.contains { $0.lastPathComponent.hasPrefix("Assembly-CSharp") }

        let evidence = assemblies.filter { !wrappers.contains($0) }
        let found = scan(evidence, for: ["SteamMatchmaking", "CreateLobby", "SendMessageToUser", "ConnectP2P",
                                         "CreateListenSocketP2P", "ConnectRelay", "CreateRelaySocket",
                                         "SendP2PPacket", "SteamInput", "GetConnectedControllers", "ActivateActionSet",
                                         "GetAuthTicketForWebApi", "GetAuthSessionTicket"])
        p.steamLobbies = found.isSuperset(of: ["SteamMatchmaking", "CreateLobby"])
        p.steamMessages = found.contains("SendMessageToUser")
        p.steamSockets = !found.isDisjoint(with: ["ConnectP2P", "CreateListenSocketP2P", "ConnectRelay", "CreateRelaySocket"])
        p.steamLegacyP2P = found.contains("SendP2PPacket")
        p.steamInput = found.contains("SteamInput") && !found.isDisjoint(with: ["GetConnectedControllers", "ActivateActionSet"])
        p.steamAuthTicket = !found.isDisjoint(with: ["GetAuthTicketForWebApi", "GetAuthSessionTicket"])
        // The game's own code is in Assembly-CSharp too: anything found there is real evidence.
        if !p.steamFeaturesCertain && (p.steamLobbies || p.steamMessages || p.steamSockets || p.steamLegacyP2P) {
            p.steamFeaturesCertain = true
        }
    }

    /// IL2CPP games. Their P/Invokes are compiled into GameAssembly.dylib and still resolve through dlsym, and code
    /// stripping usually leaves only the Steam functions the game calls. When interfaces games almost never use
    /// are present too, nothing was stripped and the list says nothing about the game.
    static func analyzeIL2CPPSteamUsage(_ gameAssembly: URL, into p: inout GameProfile) {
        let found = scan([gameAssembly], for: [
            "SteamAPI_ISteamMatchmaking_CreateLobby", "SteamAPI_ISteamNetworkingMessages_SendMessageToUser",
            "SteamAPI_ISteamNetworkingSockets_ConnectP2P", "SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P",
            "SteamAPI_ISteamNetworking_SendP2PPacket", "SteamAPI_ISteamInput_GetConnectedControllers",
            "SteamAPI_ISteamUser_GetAuthTicketForWebApi", "SteamAPI_ISteamUser_GetAuthSessionTicket",
            "SteamAPI_ISteamHTMLSurface_", "SteamAPI_ISteamParties_",
        ])
        p.steamViaFlatAPI = true
        p.steamFeaturesCertain = found.isDisjoint(with: ["SteamAPI_ISteamHTMLSurface_", "SteamAPI_ISteamParties_"])
        p.steamLobbies = found.contains("SteamAPI_ISteamMatchmaking_CreateLobby")
        p.steamMessages = found.contains("SteamAPI_ISteamNetworkingMessages_SendMessageToUser")
        p.steamSockets = !found.isDisjoint(with: ["SteamAPI_ISteamNetworkingSockets_ConnectP2P",
                                                 "SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P"])
        p.steamLegacyP2P = found.contains("SteamAPI_ISteamNetworking_SendP2PPacket")
        p.steamInput = found.contains("SteamAPI_ISteamInput_GetConnectedControllers")
        p.steamAuthTicket = p.steamFeaturesCertain && !found.isDisjoint(with: ["SteamAPI_ISteamUser_GetAuthTicketForWebApi",
                                                                               "SteamAPI_ISteamUser_GetAuthSessionTicket"])
    }

    /// Which of `tokens` occur in any of the files.
    static func scan(_ files: [URL], for tokens: [String]) -> Set<String> {
        var found = Set<String>()
        let needles = tokens.map { ($0, Data($0.utf8)) }
        for file in files {
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
            for (token, needle) in needles where !found.contains(token) && data.range(of: needle) != nil {
                found.insert(token)
            }
            if found.count == tokens.count { break }
        }
        return found
    }

    static func bundleContains(_ app: URL, where match: (String) -> Bool) -> Bool {
        guard let e = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in e {
            if match(url.lastPathComponent) { return true }
            // Big games have tens of thousands of asset files; their names never matter here.
            if url.lastPathComponent == "StreamingAssets" || url.lastPathComponent == "Content" { e.skipDescendants() }
        }
        return false
    }
}

/// Installed Steam games, read from Steam's own library manifests.
public enum SteamLibrary {
    public struct Game: Identifiable, Hashable {
        public var id: String  // Steam app ID
        public var name: String
        public var app: URL
    }

    static var steamRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
    }

    /// steamapps folders of every Steam library (the default one plus extra drives).
    static var libraryFolders: [URL] {
        var folders = [steamRoot.appendingPathComponent("steamapps")]
        if let vdf = try? String(contentsOf: steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for path in values(of: "path", in: vdf) {
                let f = URL(fileURLWithPath: path).appendingPathComponent("steamapps")
                if !folders.contains(where: { $0.standardizedFileURL == f.standardizedFileURL }) { folders.append(f) }
            }
        }
        return folders
    }

    /// Every installed Steam game that has a macOS .app.
    public static func installedGames() -> [Game] {
        var games: [Game] = []
        for folder in libraryFolders {
            let manifests = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
            for manifest in manifests {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let id = values(of: "appid", in: text).first,
                      let name = values(of: "name", in: text).first,
                      let dir = values(of: "installdir", in: text).first,
                      let app = findApp(in: folder.appendingPathComponent("common").appendingPathComponent(dir))
                else { continue }
                games.append(Game(id: id, name: name, app: app))
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Steam app ID and name of the game at `app`, if it's installed through Steam.
    public static func appID(forGameAt app: URL) -> (String?, String?) {
        let path = app.resolvingSymlinksInPath().path
        for folder in libraryFolders {
            let common = folder.appendingPathComponent("common").resolvingSymlinksInPath().path + "/"
            guard path.hasPrefix(common) else { continue }
            let installDir = String(path.dropFirst(common.count).split(separator: "/").first ?? "")
            let manifests = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("appmanifest_") }
            for manifest in manifests {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      values(of: "installdir", in: text).first == installDir else { continue }
                return (values(of: "appid", in: text).first, values(of: "name", in: text).first)
            }
        }
        return (nil, nil)
    }

    static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        let level1 = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let app = level1.first(where: { $0.pathExtension == "app" }) { return app }
        for sub in level1 where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let level2 = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            if let app = level2.first(where: { $0.pathExtension == "app" }) { return app }
        }
        return nil
    }

    /// Values of `"key" "value"` pairs in Valve's KeyValues text format.
    static func values(of key: String, in vdf: String) -> [String] {
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: key) + "\"\\s+\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: vdf, range: NSRange(vdf.startIndex..., in: vdf)).compactMap {
            Range($0.range(at: 1), in: vdf).map { String(vdf[$0]).replacingOccurrences(of: "\\\\", with: "\\") }
        }
    }
}
