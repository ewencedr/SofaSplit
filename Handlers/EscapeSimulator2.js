// Escape Simulator 2 (Steam, Unity). Online co-op through Photon.
Game.GameName = "Escape Simulator 2";
Game.GUID = "EscapeSimulator2";
Game.ExecutableName = "EscapeSimulator2.app";
Game.BundleIdentifier = "ES";
Game.SteamID = "2879840";
Game.MaxPlayers = 4;
Game.Description = "Host a co-op lobby in player 1 and join it with the lobby code from the other windows.";

Game.CloneGame = true;
Game.ChangeBundleID = true;     // separate Unity PlayerPrefs (window mode, resolution) per player
Game.PauseBetweenStarts = 4000;

// Each player gets their own saves/settings (seeded from yours), but shares the Steam client.
Game.IsolateHome = true;
Game.HomeSymlinks = ["Library/Application Support/Steam"];
Game.HomeCopies = ["Library/Application Support/Pine Studio/Escape Simulator 2"];

Game.Hook.Inject = true;
Game.Hook.GamepadRouting = true;
Game.Hook.SteamMultiplayer = true;  // every window gets its own Steam identity; lobbies + P2P run locally
Game.Hook.SteamInput = true;    // the game reads pads through Steam Input (see Player.log: "SteamInput Init Result")
Game.Hook.ForceFocus = true;
Game.Hook.Borderless = true;

Game.Play = function (Context) {
  Context.StartArguments = "-screen-fullscreen 0 -screen-width " + Context.PixelWidth +
                           " -screen-height " + Context.PixelHeight;
  // Unity also reads its window mode from PlayerPrefs; force windowed for this clone.
  Context.SetDefault("Screenmanager Fullscreen mode", 3);
  Context.SetDefault("Screenmanager Resolution Use Native", 0);
  Context.SetDefault("Screenmanager Resolution Width", Context.PixelWidth);
  Context.SetDefault("Screenmanager Resolution Height", Context.PixelHeight);
  // The game re-applies its own display settings on every scene load: make them windowed too.
  var settings = Context.GetFolder(SofaSplit.Folder.AppSupport) + "/Pine Studio/Escape Simulator 2/ES2-Settings-v10.json";
  if (Context.FileExists(settings)) {
    Context.ModifyJson(settings, "fullScreenMode", 3);
    Context.ModifyJson(settings, "screenResolutionWidth", Context.PixelWidth);
    Context.ModifyJson(settings, "screenResolutionHeight", Context.PixelHeight);
    // Everyone sits in the same room and every window would capture the same microphone.
    Context.ModifyJson(settings, "voiceChatEnabled", false);
  }
};
