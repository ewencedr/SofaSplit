// Borderlands 2 (Steam, Aspyr's Mac port, Unreal Engine 3). Co-op over the game's LAN mode.
//
// The bundle's executable, AppBundleExe, is Aspyr's launcher. Its signature covers Info.plist, so macOS kills a
// copy whose bundle ID was changed; the game itself (Contents/MacOS/BL2) doesn't, so each copy starts BL2 directly.
// All copies share one Steam account, so Steam matchmaking can't join them; UE3's LAN mode can, once every copy
// may bind the LAN discovery port (Hook.SharedUDPPorts).
Game.GameName = "Borderlands 2";
Game.GUID = "Borderlands2";
Game.ExecutableName = "Borderlands2.app";
Game.BundleIdentifier = "com.aspyr.borderlands2.steam";
Game.SteamID = "49520";
Game.MaxPlayers = 4;
Game.Description = "Player 1: set the network to LAN and start playing. Other windows: find Player 1's game " +
                   "in the LAN game list and join it. Every player picks their own character.";

Game.Executable = "Contents/MacOS/BL2";  // skip the Aspyr launcher
Game.CloneGame = true;
Game.ChangeBundleID = true;
Game.PauseBetweenStarts = 5000;

// The game keeps its settings and saves in ~/Library/Application Support/Borderlands 2. Each player gets their own
// settings (resolution, key bindings), seeded from yours, but all share your real save folder: everyone can
// pick from your characters, and progress lands where the game normally saves it.
Game.IsolateHome = true;
Game.HomeSymlinks = [
  "Library/Application Support/Steam",
  "Library/Application Support/Borderlands 2/WillowGame/SaveData",
];
Game.HomeCopies = ["Library/Application Support/Borderlands 2/WillowGame/Config"];

Game.Hook.Inject = true;
Game.Hook.GamepadRouting = true;
Game.Hook.ForceFocus = true;
Game.Hook.Borderless = true;
Game.Hook.SharedUDPPorts = "14001";  // UE3's LanAnnouncePort (BaseEngine.ini)
// Steam Input claims PlayStation pads for this game and hides them from its SDL 2.0.9, which then sees no
// controller at all (even without SofaSplit). Keep them; SDL's own PS4 driver reads them.
Game.Hook.UnhideSteamInputPads = true;

Game.Play = function (Context) {
  // The shared save folder must exist before the game follows the link into it.
  Context.MakeDir("~/Library/Application Support/Borderlands 2/WillowGame/SaveData");
  // UE3 takes the window size in points; the hook then places the window in its slot.
  Context.StartArguments = "-windowed -ResX=" + Context.Width + " -ResY=" + Context.Height + " -nostartupmovies";
  // This player's own engine settings: the same size and windowed, so a restart or the video menu doesn't go
  // back to your normal resolution. UE3 keeps the vertical field of view by default, which crops the sides of a
  // window narrower than 16:9 (side by side it's almost square and looks zoomed in): keep the horizontal one there.
  var engine = Context.HomeFolder + "/Library/Application Support/Borderlands 2/WillowGame/Config/WillowEngine.ini";
  if (Context.FileExists(engine)) {
    Context.ModifyIni(engine, "SystemSettings", "ResX", Context.Width);
    Context.ModifyIni(engine, "SystemSettings", "ResY", Context.Height);
    Context.ModifyIni(engine, "SystemSettings", "Fullscreen", "False");
    Context.ModifyIni(engine, "SystemSettings", "WindowedFullscreen", "False");
    // Every copy reads the same game ports (7777, then 7778, 7779… when taken). Starting LAN play, the copies
    // took each other's, and player 1's game never came up. Player 1 keeps the defaults, so the others still
    // find and join it; every other player gets its own block of ten.
    Context.ModifyIni(engine, "URL", "Port", 7777 + Context.PlayerID * 10);
    Context.ModifyIni(engine, "URL", "PeerPort", 7778 + Context.PlayerID * 10);
    var narrow = Context.Width / Context.Height < 16 / 9 - 0.01;
    Context.ModifyIni(engine, "Engine.LocalPlayer", "AspectRatioAxisConstraint",
                      narrow ? "AspectRatio_MaintainXFOV" : "AspectRatio_MaintainYFOV");
  }
};
