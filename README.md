# Chest Filters for RuneScape: Dragonwilds

A UE4SS Lua mod for RuneScape: Dragonwilds. It lets you tell a chest which
items it takes, so **Fill Stacks** sorts your bag into the right chests without
a "seed" item in each one.

In the game, Fill Stacks only moves an item into a chest that already holds
one. So every sorted chest needs one of each item left in it, and when crafting
from linked storage uses that last one up, the chest forgets it.

- An open chest gets a **Filters** panel on its right.
- **Drag an item onto the panel**, from your bag or from the chest. The item
  stays where it was; the panel now shows its picture. That is a filter.
- **Add all in chest** makes a filter for every kind of item the chest holds
  right now.
- **Fill Stacks** then also moves every item of a filtered kind from your bag
  into the chest, whether or not the chest holds one already.
- A filter is a note, not an item. Nothing is taken from you to set one and
  nothing sits in the chest for it, so crafting from linked storage can't use
  it up, and nothing else that looks into chests sees it.
- Each filter shows how many of that item the chest holds. With none, the
  picture is faint.
- **Click a filter** to remove it.
- Filters are saved per chest and are still there after a restart.
- Client-side only. Other players and servers don't need it.
- Doesn't change any world settings, so achievements keep working.

Built for game build 26162923 (Unreal Engine 5.6) with UE4SS v3.0.1-1217.

## Requirements

- [UE4SS for RuneScape: Dragonwilds](https://github.com/MichaelRyan2319/RSDragonwilds-UE4SS).
  Any other UE4SS v3 install works too.

## Install with Mod Loader

[Mod Loader](https://github.com/MichaelRyan2319/ModLoader) installs the mod and
keeps it up to date.

1. **Add game** and pick RuneScape: Dragonwilds. Mod Loader 1.0.1 or later sets
   the mods folder to the game's inner `RSDragonwilds` folder (the one with
   `Binaries` and `Content` in it). If you added the game with an older version,
   edit it and choose that folder.
2. **Add mod** `MichaelRyan2319/RSDragonwilds-ChestFilters`. The mod needs
   UE4SS, so Mod Loader 1.1.0 or later offers to add
   `MichaelRyan2319/RSDragonwilds-UE4SS` as well; click **Yes**. With an older
   Mod Loader, add `MichaelRyan2319/RSDragonwilds-UE4SS` yourself first.
3. Start the game, load a world and open a chest.

## Install by hand

1. Install UE4SS (see Requirements).
2. Download `ChestFilters.zip` from the [Releases](../../releases) page.
   In Steam, right-click RuneScape: Dragonwilds > Manage > Browse local files,
   then open the `RSDragonwilds` folder (the one with `Binaries` and `Content`
   in it) and extract the zip there. The mod ends up in
   `Binaries\Win64\ue4ss\Mods\ChestFilters`.
3. Start the game, load a world and open a chest.

The mod folder contains `enabled.txt`, so UE4SS loads it without any change to
`mods.txt`. To install from this repo instead of a release, copy the
`ChestFilters` folder into `Win64\ue4ss\Mods\`.

## Using it

1. Open a chest you built. The Filters panel is to the right of the chest
   window.
2. Click **Add all in chest** to make a filter for everything in it. Or drag an
   item from your bag, or from the chest, onto the panel and let go: over a
   slot to put the filter there, or anywhere else on the panel to use the first
   free slot.
3. Press **Fill Stacks** (F unless you changed it). Everything in your bag that
   matches a filter goes into the chest, along with what the game's own Fill
   Stacks moves. The panel says how many items the filters moved.

Good to know:

- The panel has one filter slot for each slot of the chest, eight to a row:
  16 on a crate, 64 on an iron chest.
- Fill Stacks leaves your **hotbar** alone, so the food and tools you carry
  there stay with you. **Quest items** are never moved. Both can be changed in
  the settings.
- If the chest is full, the items that don't fit stay in your bag.
- Only chests and other storage you built get the panel. Loot chests don't.
- A filter belongs to the chest. Take the chest down and build it again, and it
  is a new chest with no filters.
- Filters are set with the mouse, and the mod notices Fill Stacks by its
  keyboard key. On a controller the game's own Fill Stacks works as always, but
  the filters aren't used.
- In someone else's world your filters are yours alone: they are kept on your
  PC, and other players don't see them.

## Settings

`Win64\ue4ss\Mods\ChestFilters\Scripts\config.lua`; edit it in Notepad, then
restart the game.

| Setting | Default | What it does |
| --- | --- | --- |
| `IncludeHotbar` | `false` | `true` lets filters take matching items from the hotbar too |
| `IncludeQuestItems` | `false` | `true` lets filters move quest items |
| `PollMs` | `33` | How often an open chest is checked, in milliseconds: for an item dropped on the panel, for clicks on it and for the Fill Stacks key |
| `DebugLogging` | `false` | Extra lines in `UE4SS.log` |

The filters are in `Win64\ue4ss\Mods\ChestFilters\saved_chests.txt`. The mod
writes that file; updates don't touch it.

## How it works

- The panel is added to the game's own chest window, so it opens, closes and
  fades with it. Its background and slots are drawn with the materials the game
  draws its chest window and inventory slots with.
- The game says when an item is being dragged and which one
  (`DragAndDropAPI`). It ends a drag where the mouse button comes up: on one of
  its slots, or on the ground behind the windows, which drops the item there.
  The panel is neither, so it catches the button itself: while a drag is on,
  its slots are check boxes that flip when the button comes up over them. The
  mod then saves the kind of item (its data asset's path) under the chest's id
  and tells the game the drag is over (`CallUserStopDrag`). The item never left
  its slot.
- Every building has an id that the game saves with the world (`SpudGuid`).
  That is the chest's name in `saved_chests.txt`.
- The game runs its own Fill Stacks without anything a mod can listen to, so
  the mod watches the key it is bound to (read from the game's key bindings)
  while a chest is open. A moment after the key goes down it walks the bag and
  moves each stack of a filtered kind with
  `InventoryController:MoveItemBetweenInventoriesAnySlot`, the call a quick
  transfer makes: into a stack with room, or else an empty slot.
- A filter slot is clicked through an invisible check box. A click flips it,
  and the mod looks thirty times a second for flipped boxes while a chest is
  open, so no click is lost.
- The mod only reads the game's data and calls the one "move item" function.
  It writes nothing to your save.

### Achievements

The game skips achievement unlocks only in Creative and Custom worlds. This mod
never touches world difficulty or world settings. The game's mod check
(`CheckForMods`) logs a warning and marks the world as modded for people
joining, but achievements still unlocked in testing with other UE4SS mods.

## Troubleshooting

The log is `Win64\ue4ss\UE4SS.log`. Lines from this mod start with
`[ChestFilters]`. Set `DebugLogging = true` in `config.lua` to see every drag,
every chest opened and what each Fill Stacks moved.

- **No Filters panel**: check that UE4SS is installed and that the log has
  `[ChestFilters] Loaded`. The panel only shows on storage you built.
- **Fill Stacks doesn't move a filtered item**: check it isn't on your hotbar,
  and that the chest has room. If you changed the Fill Stacks key, reopen the
  chest once so the mod reads the new key.

## Uninstall

Delete `Win64\ue4ss\Mods\ChestFilters`, or remove the mod in Mod Loader.
Nothing is left in your save. Mod Loader leaves `saved_chests.txt` behind;
delete the folder by hand if you want it gone too.

## Credits

UE4SS is made by the UE4SS team ([RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS),
MIT licence).
