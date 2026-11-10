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
-- ESlateSizeRule
local SIZE_FILL = 1
-- ESlateBrushDrawType
local DRAW_NONE = 0
-- EButtonClickMethod: a click is a press and a release on the same widget, or any release on it.
local CLICK_DOWN_AND_UP, CLICK_MOUSE_UP = 0, 2

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

-- A colour as it looks on screen (0-255); the game's widgets take linear colours.
local function Screen(r, g, b)
    local function linear(v)
        v = v / 255
        if v <= 0.04045 then return v / 12.92 end
        return ((v + 0.055) / 1.055) ^ 2.4
    end
    return { R = linear(r), G = linear(g), B = linear(b), A = 1 }
end

-- The colours of the game's inventory tab buttons: a dark box with a thin edge, gold when lit.
local BUTTON_LOOKS = {
    normal = { fill = Screen(46, 44, 43), edge = Screen(62, 59, 52), text = CREAM },
    hover = { fill = Screen(108, 87, 56), edge = Screen(168, 148, 90), text = WHITE },
}

-- The panel is a small copy of the chest's own grid: eight to a row, one filter for each slot
-- of the chest. The game's slots are 60 x 66; these are four fifths of that.
local SLOT_W, SLOT_H = 48, 53
local SLOT_PAD = { Left = 2, Top = 1.5, Right = 2, Bottom = 1 }
local CELL_W = SLOT_W + SLOT_PAD.Left + SLOT_PAD.Right
local COLUMNS, MAX_ROWS = 8, 8
-- The space the game leaves between a window's edge and what is in it.
local PANEL_PAD = { Left = 20, Top = 27, Right = 20, Bottom = 34 }
local HEADER_H, HINT_H = 46, 32
local PANEL_W = COLUMNS * CELL_W + PANEL_PAD.Left + PANEL_PAD.Right
-- The gap between the chest window and this panel.
local PANEL_GAP = 2

local HINT_EMPTY = "Drag an item here. Fill Stacks and Storage Ledgers will then also move that kind of item from your bag into this chest."
local HINT_SET = "Fill Stacks and Storage Ledgers also move these from your bag into this chest. Drag an item here to add it; click one to remove it."
local HINT_ADD_ALL = "Adds a filter for every kind of item that is in this chest now."
local HINT_CLEAR = "Removes every filter from this chest."
local HINT_CLEAR_SURE = "Click again to remove every filter from this chest."

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

-- The kinds of item an inventory holds, from slot `first` to slot `last` (1 is the first slot):
-- item path -> count, and the paths in the order they come.
local function CountItems(inventory, first, last)
    local counts, order = {}, {}
    local slots = inventory.ItemSlots
    for i = first or 1, math.min(last or #slots, #slots) do
        local item = slots[i]
        if item ~= nil and item:IsValid() then
            local data = item.ItemData
            if data ~= nil and data:IsValid() then
                local path = PathOf(data)
                if not counts[path] then order[#order + 1] = path end
                counts[path] = (counts[path] or 0) + item.Count
            end
        end
    end
    return counts, order
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

local function FirstFreeSlot(list, slotCount)
    for number = 1, slotCount do
        if not list[number] then return number end
    end
    return nil
end

-- Puts a kind of item into a slot of a chest's panel. A chest lists each kind once, so if it
-- is in another slot already it moves.
local function SetFilter(key, number, path)
    local list = Filters[key] or {}
    for other, existing in pairs(list) do
        if existing == path then list[other] = nil end
    end
    list[number] = path
    Filters[key] = list
    SaveFilters()
end

local function RemoveFilter(key, number)
    local list = Filters[key]
    if not (list and list[number]) then return end
    list[number] = nil
    if next(list) == nil then Filters[key] = nil end
    SaveFilters()
end

-- Adds a filter for every kind of item in the chest that has none yet. Returns how many were
-- added and how many found no free slot.
local function AddAllFilters(key, inventory, slotCount)
    local list = Filters[key] or {}
    local listed = {}
    for _, path in pairs(list) do listed[path] = true end
    local added, left = 0, 0
    local _, order = CountItems(inventory)
    for _, path in ipairs(order) do
        if not listed[path] then
            local number = FirstFreeSlot(list, slotCount)
            if number then
                list[number] = path
                added = added + 1
            else
                left = left + 1
            end
        end
    end
    if added > 0 then
        Filters[key] = list
        SaveFilters()
    end
    return added, left
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

-- The keyboard and mouse keys Fill Stacks is on. The game calls its own Fill Stacks without
-- anything a mod could listen to, so the mod watches the key. Returns the keys, their names,
-- and whether they are the keys in use now (the player's own bindings) or the game's defaults.
local function FillStacksKeys(main)
    local names, seen = {}, {}
    local live = true
    local action = "IA_WorldInventory_FillStacks"
    pcall(function() action = main.FillStacksInputAction:GetFName():ToString() end)
    local function add(mappings)
        for i = 1, #mappings do
            local mapping = mappings[i]
            local mapped = mapping.Action
            if mapped ~= nil and mapped:IsValid() and mapped:GetFName():ToString() == action then
                local key = mapping.Key.KeyName:ToString()
                -- On a controller Fill Stacks shares its button with Take All.
                if key ~= "None" and key:sub(1, 7) ~= "Gamepad" and not seen[key] then
                    seen[key] = true
                    names[#names + 1] = key
                end
            end
        end
    end
    -- The keys in use now, with the player's own bindings...
    pcall(function()
        local input = FindFirstOf("EnhancedPlayerInput")
        if Valid(input) then add(input.EnhancedActionMappings) end
    end)
    -- ...or else the game's defaults. (The chest window's keys join the keys in use a moment
    -- after it opens.)
    if #names == 0 then
        live = false
        pcall(function() add(main.WorldInventoryMappingContext.Mappings) end)
    end
    if #names == 0 then names[1] = "F" end
    local keys = {}
    for _, name in ipairs(names) do keys[#keys + 1] = { KeyName = FName(name) } end
    return keys, table.concat(names, ", "), live
end

-- Typing a name for the chest isn't asking for Fill Stacks.
local function TypingName(main)
    local ok, typing = pcall(function() return main.VerticalNavigation.ChestNameText:HasKeyboardFocus() end)
    return ok and typing == true
end

-- The slots of a bag that a filter may take from (1 is the first slot). The bag is one long
-- row: the hotbar, then Items, Runes and Ammunition, then Quest Items.
local function BagRange(bag)
    local hotbar = 8
    pcall(function() hotbar = bag.NumberOfQuickActionSlots end)
    local first = config.IncludeHotbar and 1 or hotbar + 1
    local last = #bag.ItemSlots
    if not config.IncludeQuestItems then last = math.min(last, hotbar + 96) end
    return first, last
end

-- Moves every item of a filtered kind from a bag into the chest, through the bag owner's
-- inventory controller. Returns what it was asked to move, to be counted afterwards.
local function Deposit(bag, controller, inventory, key)
    local list = Filters[key]
    if not list then return nil end
    if not (Valid(bag) and Valid(controller)) then return nil end
    local wanted = {}
    for _, path in pairs(list) do wanted[path] = true end

    local slots = bag.ItemSlots
    local first, last = BagRange(bag)
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

-- How many of the items a deposit was asked to move are still in the bag.
local function LeftInBag(bag, deposit)
    local left = 0
    for path, count in pairs(CountItems(bag, deposit.first, deposit.last)) do
        if deposit.wanted[path] then left = left + count end
    end
    return left
end

------------------------------------------------------------------ the Storage Ledger

-- A Storage Ledger sends what the player carries to the linked chests around it. For each
-- chest it asks the game whether Fill Stacks would move anything (CouldFillStacks) and, if so,
-- has the game do it (FillStacks). Both are called from the ledger's blueprint, so a mod can
-- listen to them: a chest whose filters match something in the bag says yes, and gets those
-- items when it is filled. (The chest window's own Fill Stacks never comes this way.)

local playerControllerClass = nil
local playerBags = {}       -- inventory address -> whether it is a player's bag
local chestKeys = {}        -- inventory address -> { key = its chest's key or false, at = when read }
local bagKinds = { address = nil, at = 0, kinds = {} }

local function ForgetLedgerCaches()
    playerBags, chestKeys = {}, {}
    bagKinds = { address = nil, at = 0, kinds = {} }
end

local function IsPlayerBag(bag)
    if bag == nil or not bag:IsValid() then return false end
    local address = bag:GetAddress()
    local known = playerBags[address]
    if known ~= nil then return known end
    if not Valid(playerControllerClass) then playerControllerClass = StaticFindObject("/Script/Engine.PlayerController") end
    local owner = bag:GetOwner()
    known = Valid(owner) and Valid(playerControllerClass) and owner:IsA(playerControllerClass) == true
    playerBags[address] = known
    return known
end

-- A ledger asks about every chest around it, again and again while the player looks at it, so
-- what can be remembered is: which chest an inventory belongs to (for ten seconds), and what
-- the bag holds (for a quarter of a second).
local function KeyOfInventory(inventory, now)
    local address = inventory:GetAddress()
    local entry = chestKeys[address]
    if entry and now - entry.at < 10 then return entry.key end
    local key = ChestKey(inventory) or false
    chestKeys[address] = { key = key, at = now }
    return key
end

local function KindsInBag(bag, now)
    local address = bag:GetAddress()
    if bagKinds.address == address and now - bagKinds.at < 0.25 then return bagKinds.kinds end
    local first, last = BagRange(bag)
    bagKinds = { address = address, at = now, kinds = CountItems(bag, first, last) }
    return bagKinds.kinds
end

-- The chest's key if its filters would take something from the bag.
local function FiltersWant(bag, inventory, now)
    local key = KeyOfInventory(inventory, now)
    local list = key and Filters[key]
    if not list then return nil end
    local kinds = KindsInBag(bag, now)
    for _, path in pairs(list) do
        if kinds[path] then return key end
    end
    return nil
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

-- A plain box in one colour.
local function Box(tree, color)
    local image = New("/Script/UMG.Image", tree, "Image")
    image:SetColorAndOpacity(color)
    image:SetVisibility(HIT_TEST_INVISIBLE)
    return image
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

-- Everything on the panel that takes the mouse is a check box: a click flips it, and it stays
-- flipped until this mod looks, so no click is missed between two looks. The box itself draws
-- nothing; what is seen is drawn by the widgets around it.
local function ClickBox(tree, method)
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
    if method then box:SetClickMethod(method) end
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

    local count = Text(tree, "", true, 8, WHITE)
    SetFont(count, FONT_HEADER, 8, 0)
    Layer(overlay, count, Padding(0, 0, 4, 0), RIGHT, BOTTOM)

    local click = ClickBox(tree, CLICK_DOWN_AND_UP)
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

-- A button: a box with a thin edge and a label, lit while the mouse is on it.
local function Button(tree, label)
    local overlay = New("/Script/UMG.Overlay", tree, "Button")
    overlay:SetVisibility(SELF_HIT_TEST_INVISIBLE)
    local button = { root = overlay, looks = nil }
    button.edge = Box(tree, BUTTON_LOOKS.normal.edge)
    Layer(overlay, button.edge)
    button.fill = Box(tree, BUTTON_LOOKS.normal.fill)
    Layer(overlay, button.fill, Padding(1, 1, 1, 1))
    button.text = Text(tree, label, false, 9, BUTTON_LOOKS.normal.text)
    Layer(overlay, button.text, Padding(10, 3, 10, 2), CENTER, CENTER)
    button.click = ClickBox(tree, CLICK_DOWN_AND_UP)
    Layer(overlay, button.click)
    return button
end

local function PaintButton(button, hovered)
    local looks = hovered and BUTTON_LOOKS.hover or BUTTON_LOOKS.normal
    if button.looks == looks then return end
    button.looks = looks
    button.edge:SetColorAndOpacity(looks.edge)
    button.fill:SetColorAndOpacity(looks.fill)
    SetColor(button.text, looks.text)
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

    local built = { main = main, canvas = canvas, slots = {}, rows = {}, dropMode = false }

    -- Where the game put the chest window, and how wide it is.
    local left, top, width = 700, 100, 670
    pcall(function()
        local window = canvas:GetChildAt(0)
        local offsets = window.Slot.LayoutData.Offsets
        local content = main.VerticalNavigation.WidgetTree.RootWidget
        left, top, width = offsets.Left, offsets.Top, content.WidthOverride + 40
    end)

    local overlay = New("/Script/UMG.Overlay", tree, "Panel")
    overlay:SetVisibility(SELF_HIT_TEST_INVISIBLE)
    built.root = Sized(tree, overlay, PANEL_W, nil)
    built.root:SetVisibility(COLLAPSED)

    local background = New("/Script/UMG.Image", tree, "Background")
    background:SetBrushFromMaterial(Asset(MAT_PANEL))
    background:SetVisibility(HIT_TEST_INVISIBLE)
    Layer(overlay, background)

    -- The whole panel takes the mouse. The game ends a drag where the mouse button comes up:
    -- on a slot, or on the ground behind the windows, which drops the item there. Over this
    -- panel the button comes up on this box instead, and the mod ends the drag itself.
    built.catch = ClickBox(tree, CLICK_MOUSE_UP)
    Layer(overlay, built.catch)

    local column = New("/Script/UMG.VerticalBox", tree, "Column")
    column:SetVisibility(SELF_HIT_TEST_INVISIBLE)
    Layer(overlay, column, PANEL_PAD)

    -- The title, with the buttons on its right.
    local header = New("/Script/UMG.HorizontalBox", tree, "Header")
    header:SetVisibility(SELF_HIT_TEST_INVISIBLE)
    local titles = New("/Script/UMG.VerticalBox", tree, "Titles")
    titles:SetVisibility(HIT_TEST_INVISIBLE)
    titles:AddChildToVerticalBox(Text(tree, "FILTERS", true, 13, WHITE))
    titles:AddChildToVerticalBox(Text(tree, "This chest also takes:", false, 9, DIM))
    local titlesSlot = header:AddChildToHorizontalBox(titles)
    titlesSlot:SetSize({ Value = 1, SizeRule = SIZE_FILL })
    titlesSlot:SetPadding(Padding(3, 0, 0, 0))
    built.clear = Button(tree, "Clear")
    local clearSlot = header:AddChildToHorizontalBox(built.clear.root)
    clearSlot:SetVerticalAlignment(CENTER)
    clearSlot:SetPadding(Padding(0, 0, 6, 6))
    built.addAll = Button(tree, "Add all in chest")
    local buttonSlot = header:AddChildToHorizontalBox(built.addAll.root)
    buttonSlot:SetVerticalAlignment(CENTER)
    buttonSlot:SetPadding(Padding(0, 0, 3, 6))
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
    slot:SetPosition({ X = left + width + PANEL_GAP, Y = top })
    -- Under the chest window, whose "Linked" and "Private" tips open to its right.
    slot:SetZOrder(-1)

    Debug(string.format("Added the Filters panel at %.0f, %.0f", left + width + PANEL_GAP, top))
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
    for i, line in ipairs(ui.rows) do Show(line, i <= count, SELF_HIT_TEST_INVISIBLE) end
end

-- While an item is being dragged, a slot counts the mouse button coming up on it as a click,
-- wherever it went down. That is how an item is let go of on a slot. The rest of the time a
-- click is a press and a release on the slot, so nothing is removed by accident.
local function SetDropMode(on)
    if ui.dropMode == on then return end
    ui.dropMode = on
    local method = on and CLICK_MOUSE_UP or CLICK_DOWN_AND_UP
    for _, slot in ipairs(ui.slots) do
        slot.click:SetClickMethod(method)
        if slot.click:IsChecked() then slot.click:SetIsChecked(false) end
    end
    if ui.catch:IsChecked() then ui.catch:SetIsChecked(false) end
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
local drag = nil                -- the drag going on: { path }
local fillRequested = false     -- the player asked the game for Fill Stacks
local fillKeyDown = false
-- The keys Fill Stacks is on, whether they were read from the keys in use, and when.
local fillKeys, fillKeyNames, fillKeysLive, fillKeysAt = nil, nil, false, 0
local fillAt, lastFill = nil, 0
local deposit = nil             -- what the last Fill Stacks was asked to move, until it is counted
local message, messageUntil = nil, 0
local ignoreClicksUntil = 0
local nextCount = 0
local clearSure = nil           -- the Clear button was clicked once: { key, till }

-- The chest window's Fill Stacks. The game calls these itself in some cases (a guest in someone
-- else's world, say); where it does, they are a second way to hear about it.
local function OnFillStacksAsked()
    if not stopped then fillRequested = true end
end

-- A ledger asking whether Fill Stacks would move anything from a player's bag into a chest.
-- Returning true makes that the game's answer; returning nothing leaves the game's own.
local function OnCouldFillStacks(bagParam, inventoryParam)
    if stopped then return end
    local ok, want = pcall(function()
        local bag, inventory = bagParam:get(), inventoryParam:get()
        if not IsPlayerBag(bag) or inventory == nil or not inventory:IsValid() then return false end
        return FiltersWant(bag, inventory, os.clock()) ~= nil
    end)
    if not ok then
        Report(false, want)
        return
    end
    if want then return true end
end

-- A ledger filling a chest from a player's bag. The filtered items go first; the game's own
-- Fill Stacks follows. Returning true tells the ledger something was moved, so it shows its
-- lights flying to the chest.
local function OnFillStacks(bagParam, inventoryParam)
    if stopped then return end
    local ok, moved = pcall(function()
        local bag, inventory = bagParam:get(), inventoryParam:get()
        if not IsPlayerBag(bag) or inventory == nil or not inventory:IsValid() then return 0 end
        local key = FiltersWant(bag, inventory, os.clock())
        if not key then return 0 end
        local done = Deposit(bag, bag:GetOwner().InventoryController, inventory, key)
        if not done then return 0 end
        bagKinds.at = 0     -- the bag has changed
        local count = done.before - LeftInBag(bag, done)
        Debug(string.format("Storage Ledger: %d of %d filtered items moved into chest %s", count, done.before, key))
        return count
    end)
    if not ok then
        Report(false, moved)
        return
    end
    if moved > 0 then return true end
end

local HOOKS = {
    { path = "/Script/Dominion.WorldActorInventoryUIAPI:HandleFillStacksByPlayer", call = OnFillStacksAsked },
    { path = "/Script/Dominion.InventoryUIAPI:HandleFillStacksInWorldInventory", call = OnFillStacksAsked },
    { path = "/Script/Dominion.InventoryController:Server_FillStacksBetweenInventories", call = OnFillStacksAsked },
    { path = "/Script/Dominion.InventoryComponent:CouldFillStacks", call = OnCouldFillStacks },
    { path = "/Script/Dominion.InventoryComponent:FillStacks", call = OnFillStacks },
}
local nextHookTry = 0

-- The game's functions aren't all there in the first seconds after it starts.
local function HookGame(now)
    if now < nextHookTry then return end
    nextHookTry = now + 5
    local missing = false
    for _, hook in ipairs(HOOKS) do
        if not hook.done then
            hook.done = pcall(RegisterHook, hook.path, hook.call)
            if hook.done then Debug("Listening to " .. hook.path) else missing = true end
        end
    end
    if not missing then nextHookTry = math.huge end
end

local function CloseChest()
    chest, drag, fillAt, deposit = nil, nil, nil, nil
    fillRequested, fillKeyDown = false, false
    if ui and Valid(ui.root) then pcall(SetDropMode, false) end
end

local function Say(text, now, seconds)
    message, messageUntil = text, now + (seconds or 3)
end

local function UpdateUi(now, pc)
    local main = ui.main
    -- The chest window is always there; closed, it is hidden.
    local visibility = main:GetVisibility()
    local inventory = nil
    if visibility ~= COLLAPSED and visibility ~= HIDDEN then
        local api = main.WorldInventoryManagerAPI
        inventory = Valid(api) and api.InventoryComponent or nil
    end
    if not Valid(inventory) then
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
        local rows = math.ceil((inventory.MaxSlotCount or 32) / COLUMNS)
        rows = math.max(1, math.min(MAX_ROWS, rows))
        chest = { address = address, inventory = inventory, key = key, slotCount = rows * COLUMNS }
        if key then
            SetRows(rows)
            -- Read the Fill Stacks keys again now and then; the player can change them.
            if not fillKeysLive or now - fillKeysAt > 60 then chest.readKeysAt = now + 0.3 end
        end
        nextCount, message = 0, nil
        Debug(string.format("Chest %s opened, %s slots", tostring(key), tostring(inventory.MaxSlotCount)))
    end
    if not chest.key then
        Show(ui.root, false)
        fillRequested = false
        return
    end
    Show(ui.root, true, SELF_HIT_TEST_INVISIBLE)

    if not fillKeys or (chest.readKeysAt and now >= chest.readKeysAt) then
        chest.readKeysAt = nil
        local keys, names, live = FillStacksKeys(main)
        if live or not fillKeysLive then
            if names ~= fillKeyNames then Debug("Fill Stacks is on " .. names .. (live and "" or " (the game's default)")) end
            fillKeys, fillKeyNames, fillKeysLive, fillKeysAt = keys, names, live, now
        end
    end

    local filters = Filters[chest.key] or {}

    -- What the chest holds, for the numbers on the filters.
    if now >= nextCount then
        nextCount = now + 0.5
        chest.counts = CountItems(inventory)
    end
    local counts = chest.counts or {}

    -- Is an item being dragged?
    local dragApi = main.DragAndDropAPI
    local dragging = Valid(dragApi) and dragApi:IsDragInProgress() == true
    if dragging and not drag then
        drag = { path = DraggedPath(dragApi) }
        SetDropMode(true)
        Debug("Drag started: " .. tostring(drag.path))
    elseif drag and not dragging then
        -- It ended somewhere else.
        Debug("Drag ended away from the panel")
        drag = nil
        SetDropMode(false)
        ignoreClicksUntil = now + 0.3
    end

    -- The slots.
    local hint = nil
    local any = false
    local droppedOn = nil       -- the slot the dragged item was let go of on; 0 for the panel
    local overPanel = ui.catch:IsHovered() == true
    for number, slot in ipairs(ui.slots) do
        if number <= chest.slotCount then
            local path = filters[number]
            if path then any = true end
            local hovered = slot.click:IsHovered() == true
            local clicked = Clicked(slot.click)
            if dragging then
                if hovered then overPanel = true end
                if clicked then droppedOn = number end
                FillSlot(slot, path, path and counts[path] or 0, hovered)
            else
                FillSlot(slot, path, path and counts[path] or 0, hovered and path ~= nil)
                if clicked and path and now >= ignoreClicksUntil then
                    RemoveFilter(chest.key, number)
                    Say(NameOf(path) .. " removed.", now)
                elseif hovered and path then
                    hint = NameOf(path) .. ": click to remove."
                end
            end
        end
    end
    if Clicked(ui.catch) and dragging and not droppedOn then droppedOn = 0 end

    -- An item let go of on the panel.
    if drag and droppedOn then
        local list = Filters[chest.key] or {}
        local number = droppedOn > 0 and droppedOn or FirstFreeSlot(list, chest.slotCount)
        if not drag.path then
            Say("That can't be a filter.", now)
        elseif number then
            SetFilter(chest.key, number, drag.path)
            Say(NameOf(drag.path) .. " added.", now)
        else
            Say("No free filter slot. Click a filter to remove it.", now, 4)
        end
        Debug(string.format("Dropped %s on %s", tostring(drag.path), tostring(number)))
        -- The item never left its slot; the game only has to stop showing it on the mouse.
        pcall(function() dragApi:CallUserStopDrag() end)
        drag, dragging = nil, false
        SetDropMode(false)
        ignoreClicksUntil = now + 0.3
        any = true
    end

    -- The Clear button: one click asks, a second within three seconds does it.
    local clear = ui.clear
    local sure = clearSure ~= nil and clearSure.key == chest.key and now < clearSure.till
    if not sure then clearSure = nil end
    local clearHovered = clear.click:IsHovered() == true and not dragging
    ShowText(clear.text, sure and "Sure?" or "Clear")
    PaintButton(clear, clearHovered or sure)
    if Clicked(clear.click) and not dragging and now >= ignoreClicksUntil then
        if sure then
            Filters[chest.key] = nil
            SaveFilters()
            clearSure, any = nil, false
            Say("All filters removed from this chest.", now)
            Debug("Cleared chest " .. chest.key)
        elseif any then
            clearSure = { key = chest.key, till = now + 3 }
        else
            Say("This chest has no filters.", now)
        end
    elseif clearHovered then
        hint = sure and HINT_CLEAR_SURE or HINT_CLEAR
    end

    -- The Add all button.
    local button = ui.addAll
    local buttonHovered = button.click:IsHovered() == true and not dragging
    PaintButton(button, buttonHovered)
    if Clicked(button.click) and not dragging and now >= ignoreClicksUntil then
        local added, left = AddAllFilters(chest.key, inventory, chest.slotCount)
        if added > 0 and left > 0 then
            Say(string.format("Added %d filter%s. No free slot for %d more.", added, added == 1 and "" or "s", left), now, 4)
        elseif added > 0 then
            Say(string.format("Added %d filter%s.", added, added == 1 and "" or "s"), now)
        elseif left > 0 then
            Say("No free filter slot. Click a filter to remove it.", now, 4)
        elseif next(counts) == nil then
            Say("The chest is empty.", now)
        else
            Say("Everything in the chest has a filter already.", now)
        end
        Debug(string.format("Add all: %d added, %d without a slot", added, left))
        hint = message
    elseif buttonHovered and not (message and now < messageUntil) then
        hint = HINT_ADD_ALL
    end

    -- Fill Stacks: the key going down, then the game's own part, then the filters.
    local down = false
    for _, key in ipairs(fillKeys) do
        if pc:IsInputKeyDown(key) then down = true end
    end
    if down and not fillKeyDown and not TypingName(main) then
        fillRequested = true
        Debug("Fill Stacks key pressed")
    end
    fillKeyDown = down
    if fillRequested then
        fillRequested = false
        if now - lastFill > 0.4 then
            lastFill = now
            fillAt = now + 0.05
        end
    end
    if fillAt and now >= fillAt then
        fillAt = nil
        deposit = Deposit(pc.InventoryComponent, pc.InventoryController, inventory, chest.key)
        if deposit then
            deposit.at = now + 0.4
            nextCount = 0
        end
    end
    if deposit and now >= deposit.at then
        -- How much of it left the bag.
        local bag = pc.InventoryComponent
        local left = Valid(bag) and LeftInBag(bag, deposit) or deposit.before
        local moved = deposit.before - left
        Debug(string.format("Fill Stacks: %d of %d filtered items moved", moved, deposit.before))
        if moved > 0 then
            Say(string.format("Filters moved %d item%s into the chest.", moved, moved == 1 and "" or "s"), now, 4)
        elseif deposit.before > 0 then
            Say("The chest has no room for the filtered items.", now, 4)
        end
        deposit = nil
        nextCount = 0
    end

    if dragging and overPanel and drag and drag.path then hint = "Let go to add " .. NameOf(drag.path) .. "." end
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
    -- Another world: what was remembered about the last one's chests no longer holds.
    ForgetLedgerCaches()
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
    HookGame(now)
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
