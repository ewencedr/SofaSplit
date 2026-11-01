## Install

1. Download **SofaSplit-….zip** below and double-click it.
2. Drag **SofaSplit.app** into your **Applications** folder.
3. Open it. macOS will say it can't verify the app, because SofaSplit isn't signed with a paid Apple
   Developer certificate. Click **Done**, then open **System Settings → Privacy & Security**, scroll down to
   *"SofaSplit" was blocked…* and click **Open Anyway**. You only need to do this once.

Requires macOS 14 or later, on Apple Silicon or Intel.

See the [README](https://github.com/ewencedr/SofaSplit#readme) for how to add games and connect players.

## What it does

- **Split-screen for online-only games:** one copy of the game per player, one controller per window, windows
  tiled on your screen. For Steam games that use Steam lobbies, the copies can join each other on one account.
- **Shared screen** for games with their own local co-op: one window that sees every controller.
- **PlayStation controllers in older games:** PS4 controllers on Bluetooth work in games that can't read them on
  current macOS (Unity's old input system), and can be presented with Xbox button numbering where a game expects it.
- Add games from your Steam library; SofaSplit checks each game and picks the right settings.

## Which games

Tested and working: **Escape Simulator 2**, **Human Fall Flat** and **Monster Prom**.

SofaSplit does **not** work with every game yet. Each game handles controllers, windows and multiplayer
differently, and many haven't been tried. Known not to work: games whose online service checks the Steam account
(e.g. Golf With Your Friends), games that reach Steam from native code, and games with anti-cheat. When you add a
game, SofaSplit tells you how likely it is to work. Please
[report](https://github.com/ewencedr/SofaSplit/issues/new/choose) any game you try, working or not.
