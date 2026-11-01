// Human Fall Flat (Steam, Unity). Online co-op through Steam lobbies and Steam's older P2P networking.
Game.GameName = "Human Fall Flat";
Game.GUID = "HumanFallFlat";
Game.ExecutableName = "Human.app";
Game.BundleIdentifier = "unity.NoBrakesGames.Human";
Game.SteamID = "477160";
Game.MaxPlayers = 8;
Game.Description = "Player 1: Play → Online → Host, then Start. Other windows: Play → Online and pick Player 1's game.";

Game.CloneGame = true;
Game.ChangeBundleID = true;     // progress and settings are Unity PlayerPrefs, so a bundle ID per player separates them
Game.PauseBetweenStarts = 3000;

Game.Hook.Inject = true;
Game.Hook.GamepadRouting = true;
Game.Hook.SteamMultiplayer = true;  // own Steam identity per window; the lobby list shows the other windows' games
Game.Hook.ForceFocus = true;
Game.Hook.Borderless = true;

Game.Play = function (Context) {
  Context.StartArguments = "-screen-fullscreen 0 -screen-width " + Context.PixelWidth +
                           " -screen-height " + Context.PixelHeight;
  Context.SetDefault("Screenmanager Is Fullscreen mode", 0);  // Unity 2017 key
  Context.SetDefault("Screenmanager Fullscreen mode", 3);
  Context.SetDefault("Screenmanager Resolution Width", Context.PixelWidth);
  Context.SetDefault("Screenmanager Resolution Height", Context.PixelHeight);
};
