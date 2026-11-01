// Fallback handler for any game without a dedicated one. SofaSplit analyzes the game when it's added and
// turns on the matching settings in the app (Steam app ID, Steam Input, Steam multiplayer, separate saves),
// which override the defaults below.
Game.GameName = "Generic game";
Game.GUID = "";  // empty: derived from the game's name
Game.MaxPlayers = 8;
Game.Description = "Clones the game per player, gives each window its own gamepad and tiles the windows.";

Game.CloneGame = true;
Game.ChangeBundleID = true;
Game.PauseBetweenStarts = 2000;

Game.Hook.Inject = true;
Game.Hook.GamepadRouting = true;
Game.Hook.ForceFocus = true;
Game.Hook.Borderless = true;

Game.Play = function (Context) {
  // Unity is the most common engine on macOS. It takes the window size from these arguments and from its
  // saved preferences; other games ignore both.
  Context.StartArguments += " -screen-fullscreen 0 -screen-width " + Context.PixelWidth +
                            " -screen-height " + Context.PixelHeight;
  Context.SetDefault("Screenmanager Fullscreen mode", 3);  // windowed
  Context.SetDefault("Screenmanager Resolution Use Native", 0);
  Context.SetDefault("Screenmanager Resolution Width", Context.PixelWidth);
  Context.SetDefault("Screenmanager Resolution Height", Context.PixelHeight);
};
