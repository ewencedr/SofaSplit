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
