// Fallback handler used for any game without a dedicated one.
// Works best for windowed games that connect instances over LAN / localhost.
Game.GameName = "Generic game";
Game.GUID = "";  // empty: derived from the app name below
Game.MaxPlayers = 8;
Game.Description = "Generic handler: clones the app per player, routes one gamepad to each and tiles the windows.";

Game.CloneGame = true;
Game.ChangeBundleID = true;
Game.PauseBetweenStarts = 2000;

Game.Hook.Inject = true;
Game.Hook.GamepadRouting = true;
Game.Hook.ForceFocus = true;
Game.Hook.Borderless = true;

Game.Play = function (Context) {
  // Unity is the most common engine on macOS; these flags are ignored by other games.
  Context.StartArguments += " -screen-fullscreen 0 -screen-width " + Context.PixelWidth +
                            " -screen-height " + Context.PixelHeight;
};
