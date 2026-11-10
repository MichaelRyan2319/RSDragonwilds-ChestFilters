-- Chest Filters settings. Edit in Notepad, then restart the game.
--
-- Which items a chest takes is set in the game, on the Filters panel next to an open chest.
-- That is saved in saved_chests.txt next to this mod's Scripts folder, not here.
return {
    -- Fill Stacks leaves the hotbar (the eight quick slots) alone, so the food and tools you
    -- carry there stay with you. Set to true to have filters take from the hotbar too.
    IncludeHotbar = false,

    -- Quest items are never moved by a filter. Set to true to allow it.
    IncludeQuestItems = false,

    -- How often the open chest is checked, in milliseconds: for an item being dropped on the
    -- Filters panel and for clicks on it. Nothing is checked while no chest is open.
    PollMs = 33,

    -- Extra lines in UE4SS.log.
    DebugLogging = false,
}
