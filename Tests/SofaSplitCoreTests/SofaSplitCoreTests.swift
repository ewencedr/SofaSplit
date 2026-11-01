import Foundation
import Testing
@testable import SofaSplitCore

@Suite struct LayoutTests {
    let screen = CGRect(x: 0, y: 25, width: 1728, height: 1092)

    @Test(arguments: LayoutKind.allCases)
    func slotsTileTheScreenWithoutOverlap(kind: LayoutKind) {
        let rects = kind.rects(in: screen)
        #expect(rects.count == kind.slotCount)
        guard !rects.isEmpty else { return }
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(area == screen.width * screen.height)
        for (i, a) in rects.enumerated() {
            #expect(screen.contains(a))
            for b in rects[(i + 1)...] { #expect(a.intersection(b).isEmpty || a.intersection(b).width * a.intersection(b).height == 0) }
        }
    }

    @Test func firstSlotIsTopLeft() {
        let rects = LayoutKind.quad.rects(in: screen)
        #expect(rects[0].minX == screen.minX)
        #expect(rects[0].maxY == screen.maxY)  // Cocoa coordinates: top = max Y
        #expect(rects[3].minY == screen.minY)
    }
}

@Suite struct FileEditingTests {
    @Test func iniReplacesExistingKeyCaseInsensitively() {
        let out = IniFile.set("[Display]\nWidth=800\nHeight=600\n", section: "display", key: "width", value: "960")
        #expect(out == "[Display]\nwidth=960\nHeight=600\n")
    }

    @Test func iniAddsKeyAtEndOfSection() {
        let out = IniFile.set("[A]\nx=1\n\n[B]\ny=2", section: "A", key: "z", value: "3")
        #expect(out == "[A]\nx=1\nz=3\n\n[B]\ny=2")
    }

    @Test func iniAppendsMissingSection() {
        #expect(IniFile.set("[A]\nx=1", section: "B", key: "k", value: "v") == "[A]\nx=1\n\n[B]\nk=v")
    }

    @Test func keyPathsCreateNestedDictionaries() {
        var dict: [String: Any] = ["keep": 1]
        assignKeyPath(&dict, "video.window.width", 960)
        #expect(dict["keep"] as? Int == 1)
        #expect(((dict["video"] as? [String: Any])?["window"] as? [String: Any])?["width"] as? Int == 960)
    }

    @Test func argumentsHonourQuotes() {
        #expect(GameSession.splitArguments(#"-a "two words" 'single quoted' -b"#) == ["-a", "two words", "single quoted", "-b"])
        #expect(GameSession.splitArguments("  ") == [])
        #expect(GameSession.splitArguments(#"--name """#) == ["--name", ""])
    }
}

@Suite struct HandlerTests {
    func writeHandler(_ source: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sofasplit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Game.js")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func readsOptionsWithDefaults() throws {
        let h = try GameHandler(url: writeHandler("""
        Game.GameName = "My Game"; Game.GUID = "My Game!"; Game.MaxPlayers = 3;
        Game.Hook.ForceFocus = false; Game.Environment = { A: "1" }; Game.CopyFiles = ["a -> b"];
        """))
        #expect(h.gameName == "My Game")
        #expect(h.guid == "MyGame")
        #expect(h.maxPlayers == 3)
        #expect(h.bool("Hook.ForceFocus", default: true) == false)
        #expect(h.bool("Hook.Borderless", default: true) == true)
        #expect(h.dictionary("Environment") == ["A": "1"])
        #expect(h.strings("CopyFiles") == ["a -> b"])
        #expect(h.isGeneric)
    }

    @Test func matchesByAppName() throws {
        let h = try GameHandler(url: writeHandler(#"Game.ExecutableName = "Some Game.app";"#))
        #expect(h.matches(URL(fileURLWithPath: "/Applications/Some Game.app")))
        #expect(!h.matches(URL(fileURLWithPath: "/Applications/Other.app")))
    }

    @Test func playCanChangeArgumentsEnvironmentAndFiles() throws {
        let url = try writeHandler("""
        Game.Play = function (Context) {
          Context.StartArguments += " -w " + Context.PixelWidth + " -p " + Context.PlayerNumber;
          Context.Environment["PLAYER"] = "" + Context.PlayerID;
          Context.ModifyJson("settings.json", "display.fullscreen", false);
          Context.WriteFile("notes.txt", "hello");
        };
        """)
        let root = url.deletingLastPathComponent()
        let ctx = PlayContext(playerIndex: 1, playerCount: 2, frame: CGRect(x: 0, y: 0, width: 960, height: 540), scale: 2,
                              instanceRoot: root, appURL: nil, homeURL: nil, bundleIdentifier: nil,
                              startArguments: "-windowed", environment: [:], assignment: .keyboardMouse)
        let (args, env) = try GameHandler(url: url).runPlay(ctx)
        #expect(args == "-windowed -w 1920 -p 2")
        #expect(env == ["PLAYER": "1"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("settings.json"))) as? [String: Any]
        #expect((json?["display"] as? [String: Any])?["fullscreen"] as? Bool == false)
        #expect(try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8) == "hello")
    }

    @Test func scriptErrorsAreReported() throws {
        #expect(throws: HandlerError.self) { try GameHandler(url: writeHandler("Game.GameName = ;")) }
        let h = try GameHandler(url: writeHandler("Game.Play = function () { undefinedFunction(); };"))
        let ctx = PlayContext(playerIndex: 0, playerCount: 1, frame: .zero, scale: 1,
                              instanceRoot: h.url.deletingLastPathComponent(), appURL: nil, homeURL: nil,
                              bundleIdentifier: nil, startArguments: "", environment: [:], assignment: .none)
        #expect(throws: HandlerError.self) { try h.runPlay(ctx) }
    }
}

@Suite struct AnalyzerTests {
    /// A minimal Unity (Mono) app bundle; `assemblies` maps DLL names to text they should contain.
    func fakeUnityGame(steam: Bool = true, assemblies: [String: String], plugins: [String] = []) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("sofasplit-tests-\(UUID().uuidString)/Game.app")
        let contents = app.appendingPathComponent("Contents")
        let managed = contents.appendingPathComponent("Resources/Data/Managed")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try Data().write(to: contents.appendingPathComponent("Frameworks/UnityPlayer.dylib"))
        try "Acme\nBest Game".write(to: contents.appendingPathComponent("Resources/Data/app.info"), atomically: true, encoding: .utf8)
        if steam {
            let plugin = contents.appendingPathComponent("PlugIns/steam_api.bundle/Contents/MacOS")
            try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
            try Data().write(to: plugin.appendingPathComponent("libsteam_api.dylib"))
        }
        for name in plugins {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("PlugIns/\(name)"), withIntermediateDirectories: true)
        }
        for (name, text) in assemblies { try Data(text.utf8).write(to: managed.appendingPathComponent(name)) }
        return app
    }

    let wrapper = "SteamAPI_ISteamMatchmaking_CreateLobby SteamAPI_ISteamNetworkingSockets_ConnectP2P SteamAPI_ISteamNetworking_SendP2PPacket SteamInput ActivateActionSet"

    @Test func lobbyAndMessagingGameIsLikelyAndGetsSteamSettings() throws {
        let p = GameAnalyzer.analyze(try fakeUnityGame(assemblies: [
            "com.rlabrecque.steamworks.net.dll": wrapper,
            "Game.Core.dll": "SteamMatchmaking CreateLobby SendMessageToUser SteamInput GetConnectedControllers",
        ]))
        #expect(p.engine == .unity && p.unityScripting == "Mono")
        #expect(p.steamViaFlatAPI && p.steamFeaturesCertain)
        #expect(p.steamLobbies && p.steamMessages && p.steamInput)
        #expect(!p.steamSockets && !p.steamLegacyP2P)  // only in the wrapper, so not evidence
        #expect(p.assessment.verdict == .likely)
        let o = p.suggestedOptions
        #expect(o["Hook.SteamMultiplayer"] == .bool(true))
        #expect(o["Hook.SteamInput"] == .bool(true))
        #expect(o["IsolateHome"] == .bool(true))
        #expect(o["HomeCopies"] == .strings(["Library/Application Support/Acme/Best Game"]))
    }

    @Test func socketsOnlyGameIsUnlikely() throws {
        let p = GameAnalyzer.analyze(try fakeUnityGame(assemblies: [
            "Steamworks.NET.dll": wrapper,
            "Assembly-CSharp.dll": "SteamNetworkingSockets ConnectP2P CreateListenSocketP2P",
        ]))
        #expect(p.steamSockets && !p.steamMessages)
        #expect(p.assessment.verdict == .unlikely)
        #expect(p.suggestedOptions["Hook.SteamMultiplayer"] == nil)
    }

    @Test func wrapperInsideGameAssemblyIsUncertain() throws {
        let p = GameAnalyzer.analyze(try fakeUnityGame(assemblies: ["Assembly-CSharp-firstpass.dll": wrapper]))
        #expect(p.steamViaFlatAPI && !p.steamFeaturesCertain)
        #expect(p.assessment.verdict == .maybe)
        #expect(p.suggestedOptions["Hook.SteamMultiplayer"] == nil)
    }

    @Test func nativeSteamBridgeCannotBeEmulated() throws {
        let p = GameAnalyzer.analyze(try fakeUnityGame(assemblies: ["Framework.dll": "SteamMatchmaking CreateLobby"],
                                                       plugins: ["Native.bundle"]))
        #expect(p.usesSteam && !p.steamViaFlatAPI)
        #expect(p.assessment.reasons.contains { $0.contains("native code") })
    }

    @Test func gameWithoutSteamMightWorkOverLAN() throws {
        let p = GameAnalyzer.analyze(try fakeUnityGame(steam: false, assemblies: ["Assembly-CSharp.dll": "LAN"]))
        #expect(!p.usesSteam)
        #expect(p.assessment.verdict == .maybe)
    }

    /// A minimal Unity IL2CPP app bundle: the Steam P/Invokes live in GameAssembly.dylib, assembly names in the metadata.
    func fakeIL2CPPGame(gameAssembly: String, metadata: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("sofasplit-tests-\(UUID().uuidString)/Game.app")
        let contents = app.appendingPathComponent("Contents")
        let meta = contents.appendingPathComponent("Resources/Data/il2cpp_data/Metadata")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try Data().write(to: contents.appendingPathComponent("Frameworks/UnityPlayer.dylib"))
        try Data(gameAssembly.utf8).write(to: contents.appendingPathComponent("Frameworks/GameAssembly.dylib"))
        try Data(metadata.utf8).write(to: meta.appendingPathComponent("global-metadata.dat"))
        let plugin = contents.appendingPathComponent("PlugIns/steam_api.bundle")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        return app
    }

    @Test func legacyP2PGameWithLobbiesIsLikely() throws {
        // Older Steamworks.NET compiled into firstpass, the game's own code in Assembly-CSharp (Human Fall Flat).
        let p = GameAnalyzer.analyze(try fakeUnityGame(assemblies: [
            "Assembly-CSharp-firstpass.dll": wrapper,
            "Assembly-CSharp.dll": "SteamMatchmaking CreateLobby SendP2PPacket",
        ]))
        #expect(p.steamFeaturesCertain && p.steamLobbies && p.steamLegacyP2P)
        #expect(p.assessment.verdict == .likely)
        #expect(p.suggestedOptions["Hook.SteamMultiplayer"] == .bool(true))
    }

    @Test func photonCheckingTheSteamAccountIsUnlikely() throws {
        // Golf With Your Friends: Steam lobbies only for invites, the game itself runs over Photon.
        let p = GameAnalyzer.analyze(try fakeIL2CPPGame(
            gameAssembly: "SteamAPI_ISteamMatchmaking_CreateLobby SteamAPI_ISteamUser_GetAuthTicketForWebApi",
            metadata: "Photon3Unity3D"))
        #expect(p.unityScripting == "IL2CPP" && p.steamFeaturesCertain)
        #expect(p.photon && p.steamAuthTicket && p.steamLobbies && !p.steamMessages)
        #expect(p.assessment.verdict == .unlikely)
        #expect(p.assessment.reasons.first?.contains("Photon") == true)
    }

    @Test func unstrippedIL2CPPIsUncertain() throws {
        let p = GameAnalyzer.analyze(try fakeIL2CPPGame(
            gameAssembly: "SteamAPI_ISteamMatchmaking_CreateLobby SteamAPI_ISteamNetworkingMessages_SendMessageToUser SteamAPI_ISteamHTMLSurface_Init",
            metadata: ""))
        #expect(!p.steamFeaturesCertain)
        #expect(p.assessment.verdict == .maybe)
        #expect(p.suggestedOptions["Hook.SteamMultiplayer"] == nil)
    }

    @Test func photonOnTheSideOfSteamNetworkingStaysLikely() throws {
        // Escape Simulator 2: Steam lobbies and messages for the game, Photon only for voice chat.
        let p = GameAnalyzer.analyze(try fakeUnityGame(assemblies: [
            "com.rlabrecque.steamworks.net.dll": wrapper,
            "Photon3Unity3D.dll": "Photon",
            "Game.Core.dll": "SteamMatchmaking CreateLobby SendMessageToUser GetAuthSessionTicket",
        ]))
        #expect(p.photon && p.steamAuthTicket)
        #expect(p.assessment.verdict == .likely)
        #expect(p.assessment.reasons.contains { $0.contains("voice chat") })
    }

    @Test func libraryDropsProfilesFromOlderAnalyzers() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","name":"Old","appPath":"/A.app","handlerFile":"Generic.js","profile":{"engine":"Unity"}}]"#
        let games = try JSONDecoder().decode([GameEntry].self, from: Data(json.utf8))
        #expect(games.count == 1 && games[0].name == "Old" && games[0].profile == nil)
        var current = GameEntry(name: "New", appPath: "/B.app", handlerFile: "Generic.js", profile: GameProfile())
        current.options = ["SteamID": .string("1")]
        let roundTrip = try JSONDecoder().decode([GameEntry].self, from: JSONEncoder().encode([current]))
        #expect(roundTrip == [current])
    }

    @Test func readsValveKeyValues() {
        let vdf = #"""
        "AppState"
        {
            "appid"		"2879840"
            "name"		"Escape Simulator 2"
            "installdir"		"Escape Simulator 2"
        }
        "libraryfolders" { "0" { "path"		"/Volumes/Games\\SteamLibrary" } }
        """#
        #expect(SteamLibrary.values(of: "appid", in: vdf) == ["2879840"])
        #expect(SteamLibrary.values(of: "installdir", in: vdf) == ["Escape Simulator 2"])
        #expect(SteamLibrary.values(of: "path", in: vdf) == [#"/Volumes/Games\SteamLibrary"#])
    }

    @Test func appSettingsOverrideTheHandler() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sofasplit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("H.js")
        try #"Game.GUID = ""; Game.GameName = "Generic game"; Game.Hook.SteamInput = false;"#.write(to: url, atomically: true, encoding: .utf8)
        let h = try GameHandler(url: url)
        #expect(h.guid == "Genericgame")  // empty GUID falls back to the name
        h.overrides = ["Hook.SteamInput": .bool(true), "HomeCopies": .strings(["a", "b"]), "GUID": .string("My Game 2")]
        #expect(h.bool("Hook.SteamInput", default: false))
        #expect(h.strings("HomeCopies") == ["a", "b"])
        #expect(h.guid == "MyGame2")
    }

    @Test func optionValuesRoundTripThroughJSON() throws {
        let options: [String: OptionValue] = ["a": .bool(true), "b": .int(3), "c": .string("x"), "d": .strings(["y"])]
        let decoded = try JSONDecoder().decode([String: OptionValue].self, from: JSONEncoder().encode(options))
        #expect(decoded == options)
    }
}
