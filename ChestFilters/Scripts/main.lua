-- Chest Filters for RuneScape: Dragonwilds
--
-- Adds a Filters panel to the right of an open chest. Drag an item onto it, from your bag or
-- from the chest, and the chest remembers that kind of item. From then on Fill Stacks also
-- moves every item of that kind from your bag into the chest, whether or not the chest holds
-- one already.
--
-- A filter is a note, not an item: nothing leaves your bag when you set one, and nothing is
-- kept in the chest for it. So crafting from linked storage, and anything else that looks into
-- chests, never sees a filter.

local config = require("config")
local UEHelpers = require("UEHelpers")

local TAG = "[ChestFilters] "
local function Log(msg) print(TAG .. tostring(msg) .. "\n") end
local function Debug(msg) if config.DebugLogging then Log(msg) end end

-- A second copy of this script (a reload while developing) first stops the one before it.
if ChestFiltersShutdown then pcall(ChestFiltersShutdown) end

-- ESlateVisibility
local VISIBLE, COLLAPSED, HIDDEN, HIT_TEST_INVISIBLE, SELF_HIT_TEST_INVISIBLE = 0, 1, 2, 3, 4
-- EHorizontalAlignment / EVerticalAlignment (0 is Fill)
local FILL, LEFT, CENTER, RIGHT, BOTTOM = 0, 1, 2, 3, 3
-- ESlateBrushDrawType
local DRAW_NONE = 0

-- The material the game draws its own inventory slots with: the background, the item's picture
-- and the orange highlight are all parameters of it.
local MAT_SLOT = "/Game/Materials/UI/MI_Item_Selected.MI_Item_Selected"
-- The background of the game's own chest window.
local MAT_PANEL = "/Game/Art/UI/ShaderWork/MI_Menu_PanelBG_Shared.MI_Menu_PanelBG_Shared"
local FONT_HEADER = "/Game/UI/Fonts/Amiri-Regular_Font.Amiri-Regular_Font"
local FONT_TEXT = "/Game/UI/Fonts/Poppins-Regular_Font.Poppins-Regular_Font"

local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local CREAM = { R = 0.88, G = 0.84, B = 0.79, A = 1 }
local DIM = { R = 0.60, G = 0.57, B = 0.53, A = 1 }

-- The game's inventory slots are 60 wide and 66 high, with these gaps around each.
local SLOT_W, SLOT_H = 60, 66
local SLOT_PAD = { Left = 2.5, Top = 2, Right = 2.5, Bottom = 1 }
local CELL_W, CELL_H = SLOT_W + SLOT_PAD.Left + SLOT_PAD.Right, SLOT_H + SLOT_PAD.Top + SLOT_PAD.Bottom
-- Four filters to a row, and as many rows as the chest has (a chest's own rows are eight wide).
local COLUMNS, MIN_ROWS, MAX_ROWS = 4, 2, 8
-- The space the game leaves between a window's edge and what is in it.
local PANEL_PAD = { Left = 20, Top = 27, Right = 20, Bottom = 34 }
local HEADER_H, HINT_H = 44, 50
local PANEL_W = COLUMNS * CELL_W + PANEL_PAD.Left + PANEL_PAD.Right
-- The gap between the chest window and this panel.
local PANEL_GAP = 2

local HINT_EMPTY = "Drag an item here. Fill Stacks will then also move that kind of item from your bag into this chest."
local HINT_SET = "Fill Stacks also takes these from your bag. Drag an item here to add it; click one to remove it."

------------------------------------------------------------------ small helpers

local function Valid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

-- Folder that holds this mod's Scripts folder, e.g. ".../Mods/ChestFilters/".
local MOD_FOLDER = (function()
    local source = debug.getinfo(1, "S").source or ""
    local dir = source:match("^@(.*[\\/])") or ""
    return (dir:gsub("[\\/]Scripts[\\/]$", "/"))
end)()

-- StaticConstructObject silently makes nothing when the name is already taken in that outer, so
-- every object gets a name of its own.
local SESSION = tostring(os.time())
local nameCount = 0
local function New(classPath, outer, name)
    nameCount = nameCount + 1
    local class = StaticFindObject(classPath)
    return StaticConstructObject(class, outer, FName(string.format("CF_%s_%s_%d", name, SESSION, nameCount)))
end

local assets = {}
local function Asset(path)
    local asset = assets[path]
    if asset == false then return nil end   -- it didn't load before; don't try on every tick
    if Valid(asset) then return asset end
    local ok, found = pcall(StaticFindObject, path)
    if ok and Valid(found) then
        asset = found
    else
        local okLoad, loaded = pcall(LoadAsset, path)
        asset = (okLoad and Valid(loaded)) and loaded or nil
    end
    assets[path] = asset or false
    return asset
end

local errors = 0
local function Report(ok, err)
    if ok or errors >= 8 then return end
    errors = errors + 1
    Log("Error: " .. tostring(err))
end

local function ClassName(object)
    return object:GetClass():GetFName():ToString()
end

------------------------------------------------------------------ items

local pathOf = {}   -- item data address -> its asset path
local function PathOf(data)
    local address = data:GetAddress()
    local path = pathOf[address]
    if path then return path end
    -- "BP_Resource_C /Game/.../ITEM_X.ITEM_X" -> "/Game/.../ITEM_X.ITEM_X"
    path = data:GetFullName():match("^%S+%s+(.+)$") or data:GetFullName()
    pathOf[address] = path
    return path
end

local nameOf = {}   -- item path -> the name the game shows
local function NameOf(path)
    local name = nameOf[path]
    if name then return name end
    local data = Asset(path)
    local ok, text = pcall(function() return data.Name:ToString() end)
    name = (ok and text and text ~= "") and text or (path:match("([^./]+)$") or path)
    nameOf[path] = name
    return name
end

local iconOf = {}   -- item path -> its picture
local function IconOf(path)
    local texture = iconOf[path]
    if Valid(texture) then return texture end
    local data = Asset(path)
    if not Valid(data) then return nil end
    local ok, iconPath = pcall(function()
        local library = Asset("/Script/Engine.Default__KismetSystemLibrary")
        return library:Conv_SoftObjectReferenceToString(data.Icon):ToString()
    end)
    texture = (ok and iconPath and iconPath ~= "") and Asset(iconPath) or nil
    iconOf[path] = texture
    return texture
end

-- How many of each kind of item an inventory holds, from slot `first` to slot `last` (1 is the
-- first slot): item path -> count.
local function CountItems(inventory, first, last)
    local counts = {}
    local slots = inventory.ItemSlots
    for i = first or 1, math.min(last or #slots, #slots) do
        local item = slots[i]
        if item ~= nil and item:IsValid() then
            local data = item.ItemData
            if data ~= nil and data:IsValid() then
                local path = PathOf(data)
                counts[path] = (counts[path] or 0) + item.Count
            end
        end
    end
    return counts
end

------------------------------------------------------------------ saved filters

-- chest key -> { [slot number on the panel] = item path }
local Filters = {}
local filtersFile = MOD_FOLDER .. "saved_chests.txt"

local function SaveFilters()
    local lines = {
        "# Chest Filters: the kinds of item each chest takes on Fill Stacks.",
        "# Written by the mod when a filter is added or removed. One line per filter:",
        "# <chest>|<slot on the Filters panel>=<item>",
    }
    local keys = {}
    for key in pairs(Filters) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local numbers = {}
        for number in pairs(Filters[key]) do numbers[#numbers + 1] = number end
        table.sort(numbers)
        for _, number in ipairs(numbers) do
            lines[#lines + 1] = string.format("%s|%d=%s", key, number, Filters[key][number])
        end
    end
    lines[#lines + 1] = ""
    local tmp = filtersFile .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        Log("Could not write " .. filtersFile)
        return
    end
    f:write(table.concat(lines, "\n"))
    f:close()
    os.remove(filtersFile)
    os.rename(tmp, filtersFile)
end

local function LoadFilters()
    Filters = {}
    local f = io.open(filtersFile, "r")
    if not f then return end
    local count = 0
    for line in f:lines() do
        local key, number, path = line:match("^([^#|][^|]*)|(%d+)=(.-)%s*$")
        if key and path ~= "" then
            Filters[key] = Filters[key] or {}
            Filters[key][tonumber(number)] = path
            count = count + 1
        end
    end
    f:close()
    Debug("Loaded " .. count .. " filters")
end

local function FirstFreeSlot(key, slotCount)
    local chest = Filters[key] or {}
    for number = 1, slotCount do
        if not chest[number] then return number end
    end
    return nil
end

-- Puts a kind of item into a slot of a chest's panel. A chest lists each kind once, so if it
-- is in another slot already it moves.
local function SetFilter(key, number, path)
    local chest = Filters[key] or {}
    for other, existing in pairs(chest) do
        if existing == path then chest[other] = nil end
    end
    chest[number] = path
    Filters[key] = chest
    SaveFilters()
end

local function RemoveFilter(key, number)
    local chest = Filters[key]
    if not (chest and chest[number]) then return end
    chest[number] = nil
    if next(chest) == nil then Filters[key] = nil end
    SaveFilters()
end

------------------------------------------------------------------ the open chest

local ZERO_GUID = "00000000000000000000000000000000"
local buildingClass = nil

-- The name a chest's filters are saved under, or nothing for an inventory that gets no panel
-- (loot chests, graves and anything else the player didn't build, or that has no Fill Stacks).
local function ChestKey(inventory)
    local owner = inventory:GetOwner()
    if not Valid(owner) then return nil end
    if not Valid(buildingClass) then buildingClass = StaticFindObject("/Script/Dominion.BaseBuildingActor") end
    if not (Valid(buildingClass) and owner:IsA(buildingClass)) then return nil end
    if inventory.bSupportsSortAndFillStacks ~= true then return nil end
    -- Every building has an id of its own that the game saves with the world.
    local ok, key = pcall(function()
        local g = owner.SpudGuid
        return string.format("%08X%08X%08X%08X", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
    end)
    if ok and key and key ~= ZERO_GUID then return key end
    -- Without one (seen by a guest in someone else's world, perhaps), where it stands.
    local okPlace, place = pcall(function()
        local v = owner:K2_GetActorLocation()
        return string.format("at_%d_%d_%d", math.floor(v.X + 0.5), math.floor(v.Y + 0.5), math.floor(v.Z + 0.5))
    end)
    return okPlace and place or nil
end

-- Moves every item of a filtered kind from the bag into the chest. Returns how many items the
-- bag held of those kinds before, and the slot range that was looked at.
local function Deposit(pc, inventory, key)
    local chest = Filters[key]
    if not chest then return nil end
    local wanted = {}
    for _, path in pairs(chest) do wanted[path] = true end

    local bag, controller = pc.InventoryComponent, pc.InventoryController
    if not (Valid(bag) and Valid(controller)) then return nil end
    local slots = bag.ItemSlots
    -- The bag is one long row: the hotbar, then Items, Runes and Ammunition, then Quest Items.
    local hotbar = 8
    pcall(function() hotbar = bag.NumberOfQuickActionSlots end)
    local first = config.IncludeHotbar and 1 or hotbar + 1
    local last = #slots
    if not config.IncludeQuestItems then last = math.min(last, hotbar + 96) end

    local before = 0
    for i = first, last do
        local item = slots[i]
        if item ~= nil and item:IsValid() then
            local data = item.ItemData
            if data ~= nil and data:IsValid() and wanted[PathOf(data)] then
                before = before + item.Count
                -- What a quick transfer does: into a stack with room, or else an empty slot.
                controller:MoveItemBetweenInventoriesAnySlot(bag, i - 1, inventory)
            end
        end
    end
    return { wanted = wanted, before = before, first = first, last = last }
end

------------------------------------------------------------------ building blocks for the panel

local fonts = {}
local function SetFont(text, path, size, spacing)
    pcall(function()
        local font = text.Font
        local object = fonts[path]
        if not Valid(object) then
            object = Asset(path)
            fonts[path] = object
        end
        if Valid(object) then
            font.FontObject = object
            font.TypefaceFontName = FName("Default")
        end
        font.Size = size
        font.LetterSpacing = spacing or 0
        text:SetFont(font)
    end)
end

local function SetColor(text, color)
    text:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
end

local function Text(tree, value, header, size, color)
    local text = New("/Script/UMG.TextBlock", tree, "Text")
    text:SetText(FText(value or ""))
    SetColor(text, color or CREAM)
    if header then SetFont(text, FONT_HEADER, size, 150) else SetFont(text, FONT_TEXT, size, 0) end
    text:SetVisibility(HIT_TEST_INVISIBLE)
    return text
end

-- Texts are only set when they change, so an open chest costs nothing while nothing happens.
local shownText = {}
local function ShowText(text, value, color)
    local address = text:GetAddress()
    local key = value .. (color and ("|" .. color.R .. color.G .. color.B) or "")
    if shownText[address] == key then return end
    shownText[address] = key
    text:SetText(FText(value))
    if color then SetColor(text, color) end
end

local function Show(widget, visible, shown)
    local want = visible and (shown or HIT_TEST_INVISIBLE) or COLLAPSED
    if widget:GetVisibility() ~= want then widget:SetVisibility(want) end
end

local function Padding(left, top, right, bottom)
    return { Left = left or 0, Top = top or 0, Right = right or 0, Bottom = bottom or 0 }
end

-- Adds a child to an overlay, filling it (an overlay puts its children top left otherwise).
local function Layer(overlay, child, padding, horizontal, vertical)
    local slot = overlay:AddChildToOverlay(child)
    slot:SetHorizontalAlignment(horizontal or FILL)
    slot:SetVerticalAlignment(vertical or FILL)
    if padding then slot:SetPadding(padding) end
    return slot
end

local function Sized(tree, child, width, height)
    local box = New("/Script/UMG.SizeBox", tree, "Box")
    if width then box:SetWidthOverride(width) end
    if height then box:SetHeightOverride(height) end
    box:SetContent(child)
    box:SetVisibility(SELF_HIT_TEST_INVISIBLE)
    return box
end

local STYLE_IMAGES = {
    "UncheckedImage", "UncheckedHoveredImage", "UncheckedPressedImage",
    "CheckedImage", "CheckedHoveredImage", "CheckedPressedImage",
    "UndeterminedImage", "UndeterminedHoveredImage", "UndeterminedPressedImage",
    "BackgroundImage", "BackgroundHoveredImage", "BackgroundPressedImage",
}

-- A slot is clicked through a check box: a click flips it, and it stays flipped until this mod
-- looks, so no click is missed between two looks. The box itself draws nothing.
local function ClickBox(tree)
    local box = New("/Script/UMG.CheckBox", tree, "Click")
    box.IsFocusable = false
    local style = box.WidgetStyle
    for _, name in ipairs(STYLE_IMAGES) do
        pcall(function()
            local brush = style[name]
            brush.DrawAs = DRAW_NONE
            brush.ImageSize.X = 0
            brush.ImageSize.Y = 0
        end)
    end
    pcall(function()
        local padding = style.Padding
        padding.Left, padding.Top, padding.Right, padding.Bottom = 0, 0, 0, 0
    end)
    return box
end

-- True once for each click.
local function Clicked(box)
    if not box:IsChecked() then return false end
    box:SetIsChecked(false)
    return true
end

-- One item slot, drawn by the game's own slot material, so it looks and lights up like the
-- slots of the chest next to it.
local function ItemSlot(tree)
    local overlay = New("/Script/UMG.Overlay", tree, "Slot")
    overlay:SetVisibility(SELF_HIT_TEST_INVISIBLE)

    local picture = New("/Script/UMG.Image", tree, "Picture")
    picture:SetBrushFromMaterial(Asset(MAT_SLOT))
    picture:SetVisibility(HIT_TEST_INVISIBLE)
    Layer(overlay, picture)

    local count = Text(tree, "", true, 10, WHITE)
    SetFont(count, FONT_HEADER, 10, 0)
    Layer(overlay, count, Padding(0, 0, 5, 0.5), RIGHT, BOTTOM)

    local click = ClickBox(tree)
    Layer(overlay, click)

    return {
        root = overlay, click = click, count = count,
        paint = picture:GetDynamicMaterial(),   -- this slot's own copy of the material
        painted = {}, texture = nil,
    }
end

local function Paint(slot, name, value)
    if slot.painted[name] == value then return end
    slot.painted[name] = value
    slot.paint:SetScalarParameterValue(FName(name), value)
end

-- Shows a kind of item in a slot (or empties it with nil). `count` is how many the chest holds:
-- with none the picture is faint, a reminder of what belongs here. `lit` shows the game's
-- orange highlight.
local function FillSlot(slot, path, count, lit)
    local texture = path and IconOf(path) or nil
    if texture and slot.texture ~= path then
        slot.texture = path
        slot.paint:SetTextureParameterValue(FName("Item Image"), texture)
    end
    local filled = texture ~= nil
    local held = filled and (count or 0) > 0
    Paint(slot, "Icon Opacity", filled and (held and 1 or 0.45) or 0)
    Paint(slot, "Burnt Desaturation", 0)
    Paint(slot, "Background Texture Opacity", filled and 1 or 0)
    Paint(slot, "Background Opacity", filled and 1 or 0.5)
    Paint(slot, "Selection Opacity", lit and 1 or 0)
    ShowText(slot.count, held and tostring(count) or "")
end

------------------------------------------------------------------ the panel

local ui = nil          -- everything this mod added to the chest window

local function UiValid()
    return ui ~= nil and Valid(ui.main) and Valid(ui.root) and Valid(ui.canvas)
end

-- Removes what an earlier copy of this mod added. UE4SS can restart its mods while the game
-- runs; the widgets the old copy made stay in the game's screen when it does.
local function RemoveLeftovers(panel)
    for i = panel:GetChildrenCount(), 1, -1 do
        local child = panel:GetChildAt(i - 1)
        if Valid(child) and child:GetFName():ToString():sub(1, 3) == "CF_" then child:RemoveFromParent() end
    end
end

local function BuildUi(main)
    local tree = main.WidgetTree
    if not Valid(tree) then return nil end
    -- The chest window's own widget fills the screen with a canvas, and the window sits in it.
    local canvas = tree.RootWidget
    if not Valid(canvas) or ClassName(canvas) ~= "CanvasPanel" then return nil end
    if not (Asset(MAT_SLOT) and Asset(MAT_PANEL)) then return nil end
    RemoveLeftovers(canvas)
    shownText = {}   -- the old panel's texts are gone, and their addresses get used again

    local built = { main = main, canvas = canvas, slots = {}, rows = {}, rowCount = MAX_ROWS }

    -- Where the game put the chest window, and how wide it is.
    local left, top, width = 700, 100, 670
    pcall(function()
        local window = canvas:GetChildAt(0)
        local offsets = window.Slot.LayoutData.Offsets
        local content = main.VerticalNavigation.WidgetTree.RootWidget
        left, top, width = offsets.Left, offsets.Top, content.WidthOverride + 40
    end)
    built.x, built.y = left + width + PANEL_GAP, top

    local overlay = New("/Script/UMG.Overlay", tree, "Panel")
    overlay:SetVisibility(SELF_HIT_TEST_INVISIBLE)
    built.root = Sized(tree, overlay, PANEL_W, nil)
    built.root:SetVisibility(COLLAPSED)

    -- The background takes the mouse, so an item let go of over this panel isn't let go of
    -- over the ground behind it.
    local background = New("/Script/UMG.Image", tree, "Background")
    background:SetBrushFromMaterial(Asset(MAT_PANEL))
    background:SetVisibility(VISIBLE)
    Layer(overlay, background)

    local column = New("/Script/UMG.VerticalBox", tree, "Column")
    column:SetVisibility(SELF_HIT_TEST_INVISIBLE)
    Layer(overlay, column, PANEL_PAD)

    local header = New("/Script/UMG.VerticalBox", tree, "Header")
    header:SetVisibility(HIT_TEST_INVISIBLE)
    header:AddChildToVerticalBox(Text(tree, "FILTERS", true, 13, WHITE)):SetPadding(Padding(3, 0, 0, 0))
    header:AddChildToVerticalBox(Text(tree, "Fill Stacks also takes:", false, 9, DIM)):SetPadding(Padding(3, 0, 0, 0))
    column:AddChildToVerticalBox(Sized(tree, header, nil, HEADER_H))

    for _ = 1, MAX_ROWS do
        local line = New("/Script/UMG.HorizontalBox", tree, "Row")
        line:SetVisibility(SELF_HIT_TEST_INVISIBLE)
        column:AddChildToVerticalBox(line)
        built.rows[#built.rows + 1] = line
        for _ = 1, COLUMNS do
            local cell = ItemSlot(tree)
            line:AddChildToHorizontalBox(Sized(tree, cell.root, SLOT_W, SLOT_H)):SetPadding(SLOT_PAD)
            built.slots[#built.slots + 1] = cell
        end
    end

    built.hint = Text(tree, HINT_EMPTY, false, 8, DIM)
    built.hint:SetAutoWrapText(true)
    column:AddChildToVerticalBox(Sized(tree, built.hint, COLUMNS * CELL_W - 6, HINT_H)):SetPadding(Padding(3, 5, 3, 0))

    local slot = canvas:AddChildToCanvas(built.root)
    slot:SetAutoSize(true)
    slot:SetPosition({ X = built.x, Y = built.y })
    -- Under the chest window, whose "Linked" and "Private" tips open to its right.
    slot:SetZOrder(-1)

    -- The whole HUD sits in a box the game can scale (the interface size setting).
    pcall(function()
        local box = main:GetParent():GetParent():GetParent()
        if ClassName(box) == "ScaleBox" then built.scaleBox = box end
    end)

    Debug(string.format("Added the Filters panel at %.0f, %.0f", built.x, built.y))
    return built
end

local nextUiSearch = 0
local function FindUi(now)
    if now < nextUiSearch then return end
    nextUiSearch = now + 3
    -- The blueprint's own template turns up here too; its parts are all None, so it's skipped.
    for _, main in ipairs(FindAllOf("WorldActorInventoryMainPanel") or {}) do
        if Valid(main) and Valid(main.VerticalNavigation) and Valid(main.WidgetTree) then
            local ok, built = pcall(BuildUi, main)
            if ok and built then
                ui = built
                return
            end
            Report(ok, built)
        end
    end
end

local function RemoveUi()
    if not ui then return end
    pcall(function() if Valid(ui.root) then ui.root:RemoveFromParent() end end)
    ui = nil
end

-- Shows as many rows as the chest has.
local function SetRows(count)
    ui.rowCount = count
    for i, line in ipairs(ui.rows) do Show(line, i <= count, SELF_HIT_TEST_INVISIBLE) end
end

local layoutLibrary = nil
-- Where the mouse is, in the units the chest window is laid out in.
local function Mouse(pc)
    if not Valid(layoutLibrary) then layoutLibrary = Asset("/Script/UMG.Default__WidgetLayoutLibrary") end
    local ok, x, y = pcall(function()
        local at = layoutLibrary:GetMousePositionOnViewport(pc)
        local x, y = at.X, at.Y
        -- With the interface scaled, the HUD grows or shrinks around the middle of the screen.
        local scale = Valid(ui.scaleBox) and ui.scaleBox.UserSpecifiedScale or 1
        if scale and scale > 0 and math.abs(scale - 1) > 0.001 then
            local size = layoutLibrary:GetViewportSize(pc)
            local dpi = layoutLibrary:GetViewportScale(pc)
            local midX, midY = size.X / dpi / 2, size.Y / dpi / 2
            x, y = midX + (x - midX) / scale, midY + (y - midY) / scale
        end
        return x, y
    end)
    if ok then return x, y end
    return nil, nil
end

-- The slot at a place on the screen (1 is top left), and whether the place is on the panel.
local function SlotAt(x, y)
    if not x then return nil, false end
    local height = PANEL_PAD.Top + HEADER_H + ui.rowCount * CELL_H + HINT_H + 5 + PANEL_PAD.Bottom
    local onPanel = x >= ui.x and x < ui.x + PANEL_W and y >= ui.y and y < ui.y + height
    local column = math.floor((x - ui.x - PANEL_PAD.Left) / CELL_W)
    local row = math.floor((y - ui.y - PANEL_PAD.Top - HEADER_H) / CELL_H)
    if column < 0 or column >= COLUMNS or row < 0 or row >= ui.rowCount then return nil, onPanel end
    return row * COLUMNS + column + 1, onPanel
end

-- The kind of item being dragged, as its asset path.
local function DraggedPath(dragApi)
    local payload = dragApi.CurrentDragPayload
    if not Valid(payload) then return nil end
    local item = payload.DraggedItem
    if not Valid(item) then
        -- A drag out of an inventory also says which slot it came from.
        pcall(function()
            local source = payload.SourceInventory
            if Valid(source) then item = source.ItemSlots[payload.InventoryIndex + 1] end
        end)
    end
    if not Valid(item) then return nil end
    local data = item.ItemData
    if not Valid(data) then return nil end
    return PathOf(data)
end

------------------------------------------------------------------ the loop

local stopped = false
local chest = nil               -- the open chest: { address, inventory, key, slotCount }
local drag = nil                -- the drag going on: { path, over, onPanel }
local fillRequested = false     -- the player asked the game for Fill Stacks
local fillAt, lastFill = nil, 0
local deposit = nil             -- what the last Fill Stacks was asked to move, until it is counted
local message, messageUntil = nil, 0
local ignoreClicksUntil = 0
local nextCount = 0

local FILL_HOOKS = {
    "/Script/Dominion.WorldActorInventoryUIAPI:HandleFillStacksByPlayer",
    "/Script/Dominion.InventoryUIAPI:HandleFillStacksInWorldInventory",
    "/Script/Dominion.InventoryController:Server_FillStacksBetweenInventories",
}
local hooked, nextHookTry = {}, 0

-- The game's functions aren't all there in the first seconds after it starts.
local function HookFillStacks(now)
    if now < nextHookTry then return end
    nextHookTry = now + 5
    local missing = false
    for _, path in ipairs(FILL_HOOKS) do
        if not hooked[path] then
            local ok = pcall(RegisterHook, path, function()
                if not stopped then fillRequested = true end
            end)
            hooked[path] = ok
            if ok then Debug("Hooked " .. path) else missing = true end
        end
    end
    if not missing then nextHookTry = math.huge end
end

local function CloseChest()
    chest, drag, fillAt, deposit = nil, nil, nil, nil
    fillRequested = false
end

local function UpdateUi(now, pc)
    local main = ui.main
    local visibility = main:GetVisibility()
    local api = main.WorldInventoryManagerAPI
    local inventory = Valid(api) and api.InventoryComponent or nil
    if visibility == COLLAPSED or visibility == HIDDEN or not Valid(inventory) then
        if chest then
            CloseChest()
            Show(ui.root, false)
        end
        fillRequested = false
        return
    end

    -- Another chest than the last look?
    local address = inventory:GetAddress()
    if not chest or chest.address ~= address then
        CloseChest()
        local key = ChestKey(inventory)
        local rows = math.ceil((inventory.MaxSlotCount or 32) / 8)
        rows = math.max(MIN_ROWS, math.min(MAX_ROWS, rows))
        chest = { address = address, inventory = inventory, key = key, slotCount = rows * COLUMNS }
        SetRows(rows)
        nextCount, message = 0, nil
        Debug("Chest " .. tostring(key) .. " opened, " .. tostring(inventory.MaxSlotCount) .. " slots")
    end
    if not chest.key then
        Show(ui.root, false)
        fillRequested = false
        return
    end
    Show(ui.root, true, SELF_HIT_TEST_INVISIBLE)

    local filters = Filters[chest.key] or {}

    -- What the chest holds, for the numbers on the filters.
    if now >= nextCount then
        nextCount = now + 0.5
        chest.counts = CountItems(inventory)
    end
    local counts = chest.counts or {}

    -- An item being dragged, and let go of over the panel.
    local dragApi = main.DragAndDropAPI
    local dragging = Valid(dragApi) and dragApi:IsDragInProgress() == true
    local over, onPanel = nil, false
    if dragging or drag then over, onPanel = SlotAt(Mouse(pc)) end
    if dragging then
        if not drag then
            drag = { path = DraggedPath(dragApi) }
            Debug("Drag started: " .. tostring(drag.path))
        end
        drag.over, drag.onPanel = over, onPanel
    elseif drag then
        -- The mouse hardly moves between two looks; where it was last still counts.
        if not onPanel then over, onPanel = drag.over, drag.onPanel end
        Debug(string.format("Drag ended: %s, on panel %s, slot %s", tostring(drag.path), tostring(onPanel), tostring(over)))
        if drag.path and onPanel then
            local number = over or FirstFreeSlot(chest.key, chest.slotCount)
            if number then
                SetFilter(chest.key, number, drag.path)
                filters = Filters[chest.key] or {}
                message, messageUntil = NameOf(drag.path) .. " added.", now + 3
            else
                message, messageUntil = "No free filter slot. Click a filter to remove it.", now + 4
            end
        end
        drag = nil
        ignoreClicksUntil = now + 0.3
    end

    -- Fill Stacks: the game has done its part; now the filters.
    if fillRequested then
        fillRequested = false
        if now - lastFill > 0.4 then
            lastFill = now
            fillAt = now + 0.05
        end
    end
    if fillAt and now >= fillAt then
        fillAt = nil
        deposit = Deposit(pc, inventory, chest.key)
        if deposit then
            deposit.at = now + 0.25
            nextCount = 0
        end
    end
    if deposit and now >= deposit.at then
        -- How much of it left the bag.
        local left = 0
        local bag = pc.InventoryComponent
        if Valid(bag) then
            for path, count in pairs(CountItems(bag, deposit.first, deposit.last)) do
                if deposit.wanted[path] then left = left + count end
            end
        end
        local moved = deposit.before - left
        Debug(string.format("Fill Stacks: %d of %d filtered items moved", moved, deposit.before))
        if moved > 0 then
            message, messageUntil = string.format("Filters moved %d item%s into the chest.", moved, moved == 1 and "" or "s"), now + 4
        elseif deposit.before > 0 then
            message, messageUntil = "The chest has no room for the filtered items.", now + 4
        end
        deposit = nil
        nextCount = 0
    end

    -- The slots.
    local hint = nil
    local any = false
    for number, slot in ipairs(ui.slots) do
        if number <= chest.slotCount then
            local path = filters[number]
            if path then any = true end
            local hovered = slot.click:IsHovered() == true
            local lit
            if dragging then lit = over == number else lit = hovered and path ~= nil end
            FillSlot(slot, path, path and counts[path] or 0, lit)
            if Clicked(slot.click) and path and not dragging and now >= ignoreClicksUntil then
                RemoveFilter(chest.key, number)
                message, messageUntil = NameOf(path) .. " removed.", now + 3
            elseif hovered and path and not dragging then
                hint = NameOf(path) .. ": click to remove."
            end
        end
    end
    if dragging and onPanel and drag.path then hint = "Let go to add " .. NameOf(drag.path) .. "." end
    if not hint and message and now < messageUntil then hint = message end
    ShowText(ui.hint, hint or (any and HINT_SET or HINT_EMPTY))
end

local nextControllerSearch, controller = 0, nil
local function Controller(now)
    if Valid(controller) then return controller end
    if now < nextControllerSearch then return nil end
    nextControllerSearch = now + 1
    local pc = UEHelpers.GetPlayerController()
    if not Valid(pc) then return nil end
    -- The title screen has a player controller too; it has no bag.
    local ok, bag = pcall(function() return pc.InventoryComponent end)
    if not ok or not Valid(bag) then return nil end
    controller = pc
    return pc
end

local nextStopCheck = 0
local function Tick()
    -- A loop that has been cancelled can still have one call waiting to run.
    if stopped then return end
    local now = os.clock()

    -- While developing: a file stop.txt in the mod's folder stops this copy.
    if config.DebugLogging and now >= nextStopCheck then
        nextStopCheck = now + 1
        local f = io.open(MOD_FOLDER .. "stop.txt", "r")
        if f then
            f:close()
            Log("stop.txt found: stopping.")
            ChestFiltersShutdown()
            return
        end
    end

    local pc = Controller(now)
    if not pc then return end
    HookFillStacks(now)
    if not UiValid() then
        ui = nil
        CloseChest()
        FindUi(now)
    end
    if UiValid() then Report(pcall(UpdateUi, now, pc)) end
end

-- One line about what the mod is doing, for the UE4SS console and for testing.
function ChestFiltersStatus()
    local chests, filters = 0, 0
    for _, list in pairs(Filters) do
        chests = chests + 1
        for _ in pairs(list) do filters = filters + 1 end
    end
    local parts = { "panel=" .. (UiValid() and "added" or "missing") }
    parts[#parts + 1] = "chest=" .. (chest and tostring(chest.key) or "closed")
    parts[#parts + 1] = string.format("saved=%d filters on %d chests", filters, chests)
    parts[#parts + 1] = "dragging=" .. tostring(drag ~= nil)
    parts[#parts + 1] = "errors=" .. errors
    return table.concat(parts, ", ")
end

function ChestFiltersShutdown()
    stopped = true
    if ChestFiltersLoop then pcall(CancelDelayedAction, ChestFiltersLoop) end
    ChestFiltersLoop = nil
    pcall(RemoveUi)
end

LoadFilters()
-- LoopInGameThreadWithDelay keeps all of this on the game thread.
ChestFiltersLoop = LoopInGameThreadWithDelay(config.PollMs, function() Report(pcall(Tick)) end)
Log("Loaded. An open chest has a Filters panel on its right.")
