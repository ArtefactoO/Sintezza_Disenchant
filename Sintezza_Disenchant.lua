local ADDON_NAME, ns = ...
local addon = CreateFrame("Frame")

local SPELL_ID_DISENCHANT = 13262
local BACKPACK_BAG = (Enum and Enum.BagIndex and Enum.BagIndex.Backpack) or 0
local REAGENT_BAG = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag  -- nil on Classic

-- Bags to scan: backpack + equipped bags, plus the reagent bag on Retail only.
-- Classic has no reagent bag (slot 5 there can be a bank bag), so it is omitted.
local BAGS_TO_SCAN = {}
for bag = BACKPACK_BAG, BACKPACK_BAG + (NUM_BAG_SLOTS or 4) do
    BAGS_TO_SCAN[#BAGS_TO_SCAN + 1] = bag
end
if REAGENT_BAG then
    BAGS_TO_SCAN[#BAGS_TO_SCAN + 1] = REAGENT_BAG
end
local UNCOMMON_QUALITY = (Enum and Enum.ItemQuality and Enum.ItemQuality.Uncommon) or 2
local EPIC_QUALITY = (Enum and Enum.ItemQuality and Enum.ItemQuality.Epic) or 4
local RARE_QUALITY = (Enum and Enum.ItemQuality and Enum.ItemQuality.Rare) or 3

local BIND_ON_ACQUIRE = (Enum and Enum.ItemBind and Enum.ItemBind.OnAcquire) or 1
local BIND_ON_EQUIP = (Enum and Enum.ItemBind and Enum.ItemBind.OnEquip) or 2
local BIND_ON_USE = (Enum and Enum.ItemBind and Enum.ItemBind.OnUse) or 3
local BIND_ACCOUNT = (Enum and Enum.ItemBind and Enum.ItemBind.ToWoWAccount) or 7
local BIND_BNET = (Enum and Enum.ItemBind and Enum.ItemBind.ToBnetAccount) or 8
local BIND_BNET_UNTIL_EQUIP = (Enum and Enum.ItemBind and Enum.ItemBind.ToBnetAccountUntilEquipped) or 9

local ROW_HEIGHT = 30
local ROW_SPACING = 4
local QUEUE_PANEL_WIDTH = 320

-- Shared locale table: guarantee it exists and capture the SAME table
-- Locales.lua fills, so this stays valid no matter which file loads first.
ns.L = ns.L or {}
local L = ns.L

-- Key binding support (1.7.0). The queue button needs a GLOBAL NAME so the
-- client's own binding system can target it via a "CLICK <name>:<button>"
-- binding (declared in Bindings.xml, so it also shows up under
-- Options > Key Bindings > Sintezza Disenchant). One key press = one click on this button =
-- one cast, exactly like a mouse click: all existing safety (debounce, stale
-- target check, click-edge matching) applies unchanged.
local QUEUE_BUTTON_NAME = "Sintezza_Disenchant_QueueButton"
local QUEUE_BINDING = "CLICK " .. QUEUE_BUTTON_NAME .. ":LeftButton"
-- HEADER names the section, CATEGORY gives the addon its own entry in the
-- client's Key Bindings list instead of the generic "AddOns" group.
-- The client resolves the category name from a global; which exact name it
-- looks up differs between client generations, so all three spellings are set.
_G["BINDING_HEADER_SINTEZZA_DISENCHANT"] = "Sintezza Disenchant"
_G["BINDING_CATEGORY_SINTEZZA_DISENCHANT"] = "Sintezza Disenchant"
_G["SINTEZZA_DISENCHANT"] = "Sintezza Disenchant"
-- The label follows the active mode ("Disenchant next item", "Mill next
-- item", ...). Called at load and whenever the mode changes.
local function UpdateBindingName(modeButtonTextKey)
    local verb = L[modeButtonTextKey or "DISENCHANT"] or L["DISENCHANT"]
    _G["BINDING_NAME_" .. QUEUE_BINDING] = string.format(L["HOTKEY_BINDING_NAME"], verb)
end
UpdateBindingName()

local db
local windowAppearance = Sintezza_Theme:NewWindowPreferences(function() return db end)
if Sintezza_Theme.RegisterGlobalWindowPreferences then
    Sintezza_Theme:RegisterGlobalWindowPreferences("Sintezza Disenchant", windowAppearance)
end
local items = {}
local selected = {}
local disenchantBlocked = {}
local bulkMessage
local queue = {}
local needsRefreshAfterCombat = false
-- How many items the automatic compact queue skipped SOLELY because of the
-- price threshold (set in BuildQueue, read by the surface via the getter below).
local valuableSkippedCount = 0
-- The currently selected processing mode (1.6.0). Assigned once ns.Modes is
-- built further down and re-selected from the DB in ADDON_LOADED; used at
-- runtime only, so the forward declaration here is enough.
local activeMode

local mainFrame
local mainContent
ns.ProfessionViews = {}
local listPanel
local listScrollFrame
local queuePanel
local queueScrollFrame
local statusText
local modeTabFrame
local modeTabButtons = {}
local queueInfoText
local queueButton
local queueButtonText
local blacklistOpenButton
local listRows = {}
local queueRows = {}
local blacklistRows = {}
local minimapButton

local compactFrame
local compactPreviewText
local compactIcon
local compactNameText
local compactQueueText
local compactFullButton
local compactModeSelector
local settingsFrame

local blacklistFrame
local blacklistScrollFrame
local blacklistScrollChild
local blacklistEmptyText

local RefreshUI
local RefreshList
local RefreshBlacklistUI
local ToggleBlacklistFrame
local UpdateCompactFrame
local SetCompactMode
local ToggleSettingsFrame
local UpdateModeSurface

local pendingDisenchantItem
local nextAllowedQueueClickAt = 0
local scanTooltip

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7dd3fcSintezza Disenchant:|r " .. tostring(msg))
end

local function IsSecretValue(value)
    return issecretvalue and issecretvalue(value) or false
end

-- ---------------------------------------------------------------------------
-- Shared visual building blocks
-- These tables/factories used to be copy-pasted at every call site; with one
-- definition, a look change is one edit instead of a hunt for n duplicates.
-- Sharing the backdrop TABLES across frames is safe - SetBackdrop only reads.
-- ---------------------------------------------------------------------------
local function CreateIconBorder(parent, size)
    local border = CreateFrame("Frame", nil, parent)
    border:SetSize(size, size)
    local icon = border:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    border.itemIcon = icon
    border.edge = ns.SettingsTheme:FrameIcon(border, icon)
    return border
end

local function EnsureDB()
    Sintezza_DisenchantDB = Sintezza_DisenchantDB or {}
    db = Sintezza_DisenchantDB
    if db.minimapDestination ~= "profession" and db.minimapDestination ~= "window" and db.minimapDestination ~= "stats" then
        db.minimapDestination = "window"
    end
    if type(db.minimap) ~= "table" then
        db.minimap = {}
        -- Migrate angle & visibility from the old hand-built minimap button
        if db.minimapAngle ~= nil then
            db.minimap.minimapPos = db.minimapAngle
        end
        if db.hidden ~= nil then
            db.minimap.hide = db.hidden and true or false
        end
        db.minimapAngle = nil
        db.hidden = nil
    end
    -- Blacklist: migrate the pre-1.6 flat shape ({ [key] = true }) to the per-mode
    -- shape ({ disenchant = { [key] = true }, ... }). "Already migrated" is detected
    -- by a mode sub-table being present; otherwise every flat entry moves under
    -- "disenchant" (the only mode that existed before).
    if type(db.blacklist) ~= "table" then
        db.blacklist = {}
    end
    local blacklistMigrated = type(db.blacklist.disenchant) == "table"
        or type(db.blacklist.milling) == "table"
        or type(db.blacklist.prospecting) == "table"
    if not blacklistMigrated then
        local flat = {}
        for k, v in pairs(db.blacklist) do
            if v == true then
                flat[k] = true
            end
        end
        db.blacklist = { disenchant = flat }
    end
    if db.compactMode == nil then
        db.compactMode = false
    end
    if db.ilvlCapEnabled == nil then
        db.ilvlCapEnabled = false
    end
    db.protectSets = db.protectSets ~= false
    db.skipUnknownPrice = db.skipUnknownPrice == true
    if type(db.qualityFilter) ~= "table" then
        db.qualityFilter = {}
    end
    -- Shape guard like the others: a corrupted non-table value here would
    -- crash the compact bar's SetPoint on load. nil is fine (default center).
    if db.compactPoint ~= nil and type(db.compactPoint) ~= "table" then
        db.compactPoint = nil
    end
    -- Value guard (v1.5.0): default off. priceThresholdGold nil = "unset" -
    -- the guard stays inert until the user enters a number (same idea as the
    -- ilvl cap), so a corrupted non-number is coerced back to nil, not 0.
    if type(db.priceWarnEnabled) ~= "boolean" then
        db.priceWarnEnabled = false
    end
    if db.priceThresholdGold ~= nil and type(db.priceThresholdGold) ~= "number" then
        db.priceThresholdGold = nil
    end
    -- Active processing mode (1.6.0). An unknown or not-yet-existing key (e.g. a
    -- stored "milling" before that mode ships) resolves to disenchant at load,
    -- so this can never break startup.
    if type(db.activeMode) ~= "string" then
        db.activeMode = "disenchant"
    end
    if type(db.showExpected) ~= "boolean" then db.showExpected = true end
    if type(db.externalItemTooltips) ~= "boolean" then db.externalItemTooltips = false end
end

local function GetSpellNameSafe(spellID)
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(spellID)
    end
    if GetSpellInfo then
        return GetSpellInfo(spellID)
    end
end

local function GetSpellTextureSafe(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    end
    if GetSpellTexture then
        return GetSpellTexture(spellID)
    end
end

local function GetItemInfoSafe(itemRef)
    if C_Item and C_Item.GetItemInfo then
        return C_Item.GetItemInfo(itemRef)
    end
    if GetItemInfo then
        return GetItemInfo(itemRef)
    end
end

local function PlayerKnowsSpellID(spellID)
    if not spellID then
        return false
    end
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        return C_SpellBook.IsSpellKnown(spellID)
    end
    if IsPlayerSpell then
        return IsPlayerSpell(spellID)
    end
    if IsSpellKnown then
        return IsSpellKnown(spellID)
    end
    return false
end

local function PlayerKnowsDisenchant()
    return PlayerKnowsSpellID(SPELL_ID_DISENCHANT)
end

-- ================= Material modes (1.6.0 Step 2) — FIRST CUT =================
-- Testable first cut. The spell IDs are stable/well-known; the pieces that still
-- need live Cata/MoP confirmation are the herb/ore DETECTION (item class/subclass)
-- and the failure strings. Detection is Enum-first (robust when the Enum table is
-- present) with numeric fallbacks; /sde check dumps sample trade-good class ids so
-- the numbers can be pinned down in-game. classifyFailure is deliberately inert for
-- materials in this cut, so nothing gets wrongly blacklisted during testing.
local SPELL_ID_MILLING     = 51005   -- Milling (Inscription)
local SPELL_ID_PROSPECTING = 31252   -- Prospecting (Jewelcrafting)

-- Milling/prospecting are Classic-only by product decision (Retail item structure
-- differs); offered only on a non-Retail client AND when the spell resolves.
-- Feature-detected: missing project globals -> false (mode simply not offered).
local IS_NON_RETAIL_CLIENT =
    (WOW_PROJECT_ID ~= nil and WOW_PROJECT_MAINLINE ~= nil and WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE)

local TRADEGOODS_CLASS      = (Enum and Enum.ItemClass and Enum.ItemClass.Tradegoods) or 7
-- VERIFY on Cata/MoP: Enum is tried first; these numbers are only the fallback.
local HERB_SUBCLASS         = (Enum and Enum.ItemTradegoodsSubclass and Enum.ItemTradegoodsSubclass.Herb) or 9
local METAL_STONE_SUBCLASS  = (Enum and Enum.ItemTradegoodsSubclass and Enum.ItemTradegoodsSubclass.MetalAndStone) or 7

local function GetItemClassIDs(itemLink)
    if not itemLink then
        return nil
    end
    if C_Item and C_Item.GetItemInfoInstant then
        local itemID, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(itemLink)
        return classID, subclassID, itemID
    end
    if GetItemInfoInstant then
        local itemID, _, _, _, _, classID, subclassID = GetItemInfoInstant(itemLink)
        return classID, subclassID, itemID
    end
    return nil
end

local function IsMillableHerb(itemLink)
    local classID, subclassID = GetItemClassIDs(itemLink)
    return classID == TRADEGOODS_CLASS and subclassID == HERB_SUBCLASS
end

-- "Metal & Stone" also contains bars and rough stones, so subclass alone is too
-- broad (live-confirmed on MoP). The supported TBC-through-MoP clients have a
-- finite, stable set of prospectable ores; item IDs keep detection independent of
-- the game locale and deliberately exclude precious/non-prospectable ores.
local PROSPECTABLE_ORE_IDS = {
    -- Classic/TBC
    [2770] = true,   -- Copper Ore
    [2771] = true,   -- Tin Ore
    [2772] = true,   -- Iron Ore
    [3858] = true,   -- Mithril Ore
    [10620] = true,  -- Thorium Ore
    [23424] = true,  -- Fel Iron Ore
    [23425] = true,  -- Adamantite Ore
    -- Wrath
    [36909] = true,  -- Cobalt Ore
    [36912] = true,  -- Saronite Ore
    [36910] = true,  -- Titanium Ore
    -- Cataclysm
    [53038] = true,  -- Obsidium Ore
    [52185] = true,  -- Elementium Ore
    [52183] = true,  -- Pyrite Ore
    -- Mists of Pandaria
    [72092] = true,  -- Ghost Iron Ore
    [72093] = true,  -- Kyparite
    [72094] = true,  -- Black Trillium Ore
    [72103] = true,  -- White Trillium Ore
}

local function IsProspectableOre(itemLink)
    local classID, subclassID, itemID = GetItemClassIDs(itemLink)
    return classID == TRADEGOODS_CLASS
        and subclassID == METAL_STONE_SUBCLASS
        and PROSPECTABLE_ORE_IDS[itemID] == true
end

local function StripColorCodes(text)
    if not text or text == "" then
        return ""
    end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    text = text:gsub("|H.-|h(.-)|h", "%1")
    return text
end

local function GetDisplayName(itemName, itemLink)
    local cleanedName = StripColorCodes(itemName)
    if cleanedName ~= "" then
        return cleanedName
    end

    if type(itemLink) == "string" then
        local extracted = itemLink:match("%[(.-)%]")
        extracted = StripColorCodes(extracted)
        if extracted ~= "" then
            return extracted
        end
    end

    return L["UNKNOWN_ITEM"]
end

-- A stable key for the "selected" set. Prefer the item's GUID so a checkmark
-- follows the item even when bags reshuffle after a disenchant. Falls back to
-- bag:slot+itemID on clients without the GUID API (older Classic).
local function ComputeItemKey(bag, slot, itemLink)
    if C_Item and C_Item.GetItemGUID and ItemLocation and ItemLocation.CreateFromBagAndSlot then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and C_Item.DoesItemExist and C_Item.DoesItemExist(loc) then
            local guid = C_Item.GetItemGUID(loc)
            if guid then
                return guid
            end
        end
    end
    local itemID = itemLink and itemLink:match("item:(%d+)")
    return tostring(bag) .. ":" .. tostring(slot) .. ":" .. tostring(itemID or "?")
end

local function GetItemIDFromLink(itemLink)
    if type(itemLink) ~= "string" then
        return nil
    end

    local itemID = itemLink:match("item:(%d+)")
    if itemID then
        return tonumber(itemID)
    end

    return nil
end

local function GetBlacklistKeyFromLink(itemLink)
    local itemID = GetItemIDFromLink(itemLink)
    if itemID then
        return tostring(itemID)
    end

    if type(itemLink) == "string" and itemLink ~= "" then
        local itemString = itemLink:match("|H(item:[^|]+)|h") or itemLink:match("(item:[^|]+)")
        if itemString and itemString ~= "" then
            return itemString
        end
    end

    return nil
end

-- Per-mode blacklist (1.6.0 Step 2b): an item that "cannot be milled" is not the
-- same as "cannot be disenchanted", so each mode keeps its own blacklist namespace
-- under db.blacklist[modeKey]. The lazy create keeps every caller simple.
local function GetModeBlacklist(modeKey)
    modeKey = modeKey or (activeMode and activeMode.key) or "disenchant"
    if type(db.blacklist) ~= "table" then
        db.blacklist = {}
    end
    if type(db.blacklist[modeKey]) ~= "table" then
        db.blacklist[modeKey] = {}
    end
    return db.blacklist[modeKey]
end

local function IsBlacklistedItem(itemLink)
    local blacklistKey = GetBlacklistKeyFromLink(itemLink)
    if blacklistKey == nil or not db then
        return false
    end
    return GetModeBlacklist()[blacklistKey] == true
end

local function ClearPendingDisenchant()
    pendingDisenchantItem = nil
end

local function SetPendingDisenchant(item)
    pendingDisenchantItem = {
        bag = item.bag,
        slot = item.slot,
        key = item.key,
        link = item.link,
        name = item.name or L["UNKNOWN"],
        startedAt = GetTime(),
    }
end

local function GetBagItemLinkSafe(bag, slot, info)
    if not info and C_Container and C_Container.GetContainerItemInfo then
        info = C_Container.GetContainerItemInfo(bag, slot)
    end
    local link = info and info.hyperlink
    if type(link) == "string" and not (issecretvalue and issecretvalue(link)) and link ~= "" then return link end
    local getLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
    link = getLink and getLink(bag, slot)
    if type(link) == "string" and not (issecretvalue and issecretvalue(link)) and link ~= "" then return link end
end

local function FindPendingBagLocation(item)
    local function Matches(bag, slot)
        local link = GetBagItemLinkSafe(bag, slot)
        return link == item.link and ComputeItemKey(bag, slot, link) == item.key
    end

    if Matches(item.bag, item.slot) then return item.bag, item.slot end
    if item.key:match("^%d+:%d+:") then return end

    for _, bag in ipairs(BAGS_TO_SCAN) do
        local numSlots = (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag)) or 0
        for slot = 1, numSlots do
            if Matches(bag, slot) then return bag, slot end
        end
    end

end


local function EnsureScanTooltip()
    if scanTooltip then
        return scanTooltip
    end

    scanTooltip = CreateFrame("GameTooltip", "Sintezza_Disenchant_ScanTooltip", UIParent, "GameTooltipTemplate")
    scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    return scanTooltip
end

local function GetTooltipLinesForItem(item)
    local lines = {}

    if C_TooltipInfo and C_TooltipInfo.GetBagItem and item and item.bag ~= nil and item.slot ~= nil then
        local data = C_TooltipInfo.GetBagItem(item.bag, item.slot)
        if data and type(data.lines) == "table" then
            for _, lineData in ipairs(data.lines) do
                local leftText = lineData.leftText
                local rightText = lineData.rightText
                if not IsSecretValue(leftText) and type(leftText) == "string" and leftText ~= "" then
                    lines[#lines + 1] = leftText
                end
                if not IsSecretValue(rightText) and type(rightText) == "string" and rightText ~= "" then
                    lines[#lines + 1] = rightText
                end
                local text = lineData.text
                if not IsSecretValue(text) and type(text) == "string" and text ~= "" then
                    lines[#lines + 1] = text
                end
            end
        end
        if #lines > 0 then
            return lines
        end
    end

    local tooltip = EnsureScanTooltip()
    -- Re-own before EVERY scan: Hide() at the end of this function clears the
    -- owner, and an ownerless tooltip silently yields zero lines - which would
    -- kill the tooltip fallback from the second scan onward (only relevant on
    -- clients without C_TooltipInfo, i.e. older Classic flavors).
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    tooltip:ClearLines()

    if item and item.bag ~= nil and item.slot ~= nil and tooltip.SetBagItem then
        tooltip:SetBagItem(item.bag, item.slot)
    elseif item and item.link and tooltip.SetHyperlink then
        tooltip:SetHyperlink(item.link)
    else
        return {}
    end

    for i = 1, tooltip:NumLines() or 0 do
        local left = _G["Sintezza_Disenchant_ScanTooltipTextLeft" .. i]
        local textValue = left and left:GetText()
        if not IsSecretValue(textValue) and type(textValue) == "string" and textValue ~= "" then
            lines[#lines + 1] = textValue
        end
    end
    tooltip:Hide()
    return lines
end

local function TooltipSaysCantDisenchant(item)
    if not item then
        return false
    end

    local cantBeDisenchanted = type(ERR_CANT_BE_DISENCHANTED) == "string" and string.lower(ERR_CANT_BE_DISENCHANTED) or nil

    for _, line in ipairs(GetTooltipLinesForItem(item)) do
        local cleaned = string.lower(StripColorCodes(line))
        if cantBeDisenchanted and cleaned == cantBeDisenchanted then
            return true
        end
        if cleaned:find("cannot be disenchanted", 1, true) or cleaned:find("can not be disenchanted", 1, true) then
            return true
        end
        if cleaned:find("nicht entzauberbar", 1, true) or cleaned:find("kann nicht entzaubert", 1, true) then
            return true
        end
    end

    return false
end

local function GetBindTagText(bindType, isBound)
    if bindType == BIND_BNET_UNTIL_EQUIP or bindType == BIND_ACCOUNT or bindType == BIND_BNET then
        return "|cff00ccffWB|r"
    end
    if bindType == BIND_ON_EQUIP and not isBound then
        return "|cff1eff00BoE|r"
    end
    if bindType == BIND_ON_ACQUIRE or isBound then
        return "|cff9d9d9dBoP|r"
    end
    return nil
end

-- Lowest equipped item level (slots 1-17, skipping shirt/slot 4):
-- anything below it cannot be an upgrade -> safe threshold suggestion
local function GetLowestEquippedItemLevel()
    local lowest
    for slot = 1, 17 do
        if slot ~= 4 then
            local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
            if link then
                local ilvl
                if C_Item and C_Item.GetDetailedItemLevelInfo then
                    ilvl = C_Item.GetDetailedItemLevelInfo(link)
                elseif GetDetailedItemLevelInfo then
                    ilvl = GetDetailedItemLevelInfo(link)
                end
                if ilvl and ilvl > 0 and (not lowest or ilvl < lowest) then
                    lowest = ilvl
                end
            end
        end
    end
    return lowest
end

local function IsQualityEnabled(quality)
    if not db or type(db.qualityFilter) ~= "table" then
        return true
    end
    return db.qualityFilter[quality] ~= false
end

local function IsForeverDisenchantMaterial(link)
    if not ns.EraReference or ns.EraReference.Client() ~= "forever" then return false end
    local id = GetItemIDFromLink(link)
    return id == 275724 or id == 247883 -- Hexed Pendant / Crude Wax Effigy
end

local function IsKnownDisenchantBlocked(link)
    -- Sorcerer Collar returns an invalid-item-target error in Forever 1.60.1.
    return GetItemIDFromLink(link) == 273457 and ns.EraReference ~= nil
        and ns.EraReference.Client() == "forever"
end

function ns.IsDisenchantBlocked(item)
    if IsSecretValue(item.link) or type(item.link) ~= "string" then return false end
    local key = item.guid
    if not IsSecretValue(key) and key == nil then key = item.key end
    return (not IsSecretValue(key) and key ~= nil and disenchantBlocked[key] == item.link)
        or IsKnownDisenchantBlocked(item.link)
end

local function IsReasonablyDisenchantable(itemLink, itemQuality)
    if not itemLink or not itemQuality then
        return false
    end

    if itemQuality < UNCOMMON_QUALITY or itemQuality > EPIC_QUALITY then
        return false
    end

    if IsForeverDisenchantMaterial(itemLink) then return true end

    local equippable = (C_Item and C_Item.IsEquippableItem and C_Item.IsEquippableItem(itemLink))
        or (IsEquippableItem and IsEquippableItem(itemLink))
    if equippable then return true end
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not instant then return false end
    local _, _, _, equipLoc, _, classID = instant(itemLink)
    local itemClass = Enum and Enum.ItemClass
    local armor, weapon = itemClass and itemClass.Armor or 4, itemClass and itemClass.Weapon or 2
    return (classID == armor or classID == weapon)
        and type(equipLoc) == "string" and equipLoc:find("^INVTYPE_") ~= nil
        and equipLoc ~= "INVTYPE_BODY" and equipLoc ~= "INVTYPE_TABARD"
end

local function SortItems()
    table.sort(items, function(a, b)
        if a.quality ~= b.quality then
            return a.quality > b.quality
        end
        if a.itemLevel ~= b.itemLevel then
            return a.itemLevel > b.itemLevel
        end
        return a.name < b.name
    end)
end

-- The three independent reasons an item is kept out of the AUTOMATIC compact
-- queue. Split into predicates (was one inline chain) so the "skipped solely
-- because of price" counter can ask each reason separately.
local function IsSetProtected(item)
    return db.protectSets and item.isSet == true
end

local function IsIlvlProtected(item)
    if not (db and db.ilvlCapEnabled) then
        return false
    end
    local cap = tonumber(db.ilvlCap)
    return cap ~= nil and cap >= 0 and cap < math.huge and (item.itemLevel or 0) >= cap
end

-- Price protection: an item worth more than the user's gold threshold on the
-- AH should not be auto-shredded. Central comparison (Sol's interface note 1):
-- provider values are COPPER, the user enters whole GOLD -> * 10000 here, once.
-- A nil price means "unknown" (guard off / no price addon / no data), never 0.
local function PriceProtectionThreshold()
    if not (activeMode and activeMode.usesItemProtection) then
        return nil
    end
    if not (db and db.priceWarnEnabled) then
        return nil
    end
    local threshold = tonumber(db.priceThresholdGold)
    if threshold and threshold >= 0 and threshold < math.huge then return threshold end
end

local function IsValuableItem(item)
    local threshold = PriceProtectionThreshold()
    return threshold ~= nil and item.priceCopper ~= nil and item.priceCopper >= threshold * 10000
end

-- The second result identifies an item protected solely by its market value.
local function IsAutoQueueProtected(item)
    if item.disenchantBlocked or item.excluded then return true end
    if not (activeMode and activeMode.usesItemProtection) then
        return false
    end
    local protected = item.manualOnly or IsSetProtected(item) or IsIlvlProtected(item)
    if protected then return protected end

    local valuable = IsValuableItem(item)
    return valuable or (db.skipUnknownPrice and item.priceCopper == nil and PriceProtectionThreshold() ~= nil),
        valuable
end

local function BuildQueue()
    wipe(queue)
    valuableSkippedCount = 0
    for _, item in ipairs(items) do
        if selected[item.key] and not item.disenchantBlocked and not item.excluded then
            queue[#queue + 1] = item
        end
    end

    -- Compact bar with no manual selection: queue every found item.
    -- Protected items (sets, ilvl cap, valuable) are SKIPPED here - they only
    -- enter the queue via a manual checkbox in the main window.
    if #queue == 0 and db and db.compactMode and compactFrame and compactFrame:IsShown() then
        for _, item in ipairs(items) do
            local protected, valuableOnly = IsAutoQueueProtected(item)
            if not protected then
                queue[#queue + 1] = item
            elseif valuableOnly then
                valuableSkippedCount = valuableSkippedCount + 1
            end
        end
    end
end

-- Stable interface for the surface (compact-bar counter). Returns the number
-- of items the last auto-queue build skipped purely because of the price guard.
function ns.GetValuableSkippedCount()
    return valuableSkippedCount
end

local itemLoadRefreshQueued = false
-- Retry bookkeeping per bag slot: an item whose data NEVER loads (corrupt
-- cache entry, server hiccup) must not put the rescan loop on an endless
-- 4-per-second treadmill. After the cap, that slot is skipped until its
-- content changes; the counter resets as soon as the item loads normally.
local itemLoadRetries = {}
local MAX_ITEM_LOAD_RETRIES = 10

local function QueueRefreshWhenItemLoaded(bag, slot)
    if not (Item and Item.CreateFromBagAndSlot) then
        return
    end

    local itemObj = Item:CreateFromBagAndSlot(bag, slot)
    if not itemObj or itemObj:IsItemEmpty() then
        return
    end

    itemObj:ContinueOnItemLoad(function()
        if itemLoadRefreshQueued then
            return
        end

        if not (C_Timer and C_Timer.After) then
            return
        end

        itemLoadRefreshQueued = true
        C_Timer.After(0.25, function()
            itemLoadRefreshQueued = false
            -- Compact mode counts too: right after login the item cache is
            -- cold, and without this the bar showed a partial queue until some
            -- unrelated bag event happened to arrive.
            local anyShown = (mainFrame and mainFrame:IsShown())
                or (compactFrame and compactFrame:IsShown())
            if anyShown and RefreshList then
                RefreshList()
            end
        end)
    end)
end

-- Look up an item's AH value, but ONLY when the value guard is actually active
-- (Sol's interface note 2): no price-addon calls otherwise. Returns copper +
-- source label, or nil,nil when the guard is off / no price addon / no data.
-- The provider layer already caches, so calling this per scanned item is cheap.
local function LookupItemValue(itemLink)
    if not (activeMode and activeMode.usesItemProtection) then
        return nil, nil
    end
    if PriceProtectionThreshold() == nil then
        return nil, nil
    end
    if not (ns.Prices and ns.Prices.GetValue) then
        return nil, nil
    end
    local copper, _, sourceLabel = ns.Prices.GetValue(itemLink)
    return copper, sourceLabel
end

local function ScanBags()
    wipe(items)
    local validKeys = {}
    local waiting = 0

    for _, bag in ipairs(BAGS_TO_SCAN) do
        local numSlots = (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag)) or 0
        for slot = 1, numSlots do
            local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
            local link = info and GetBagItemLinkSafe(bag, slot, info)
            if link and info.isLocked then
                -- Locked = mid-cast (the disenchant target) or on the cursor.
                -- Keep it OUT of the list/queue, but keep its selection key
                -- VALID: if the cast fails (movement, interrupt), the item
                -- returns on the next scan and must still be checked - before
                -- this, a failed cast silently wiped the user's checkmark.
                validKeys[ComputeItemKey(bag, slot, link)] = true
            elseif info then
                local itemName, _, itemQuality, _, _, _, _, _, _, itemTexture, vendorPrice, _, _, bindType, _, setID
                if link then
                    itemName, _, itemQuality, _, _, _, _, _, _, itemTexture, vendorPrice, _, _, bindType, _, setID = GetItemInfoSafe(link)
                    if itemQuality == nil and info.itemID then
                        itemName, _, itemQuality, _, _, _, _, _, _, itemTexture, vendorPrice, _, _, bindType, _, setID = GetItemInfoSafe(info.itemID)
                    end
                end
                local retryKey = bag .. ":" .. slot
                if link and itemQuality ~= nil then
                    itemLoadRetries[retryKey] = nil
                end
                local eligible = link and itemQuality ~= nil
                    and (info.stackCount or 1) >= activeMode.minStack
                    and activeMode.scanEligible(link, itemQuality, info)
                if not link or itemQuality == nil then
                    -- Item not in the client cache yet: request it and refresh
                    -- once loaded - but capped, see itemLoadRetries above.
                    waiting = waiting + 1
                    local identity = link or info.itemID or true
                    local retry = itemLoadRetries[retryKey]
                    if not retry or retry.item ~= identity then
                        retry = { item = identity, attempts = 0 }
                        itemLoadRetries[retryKey] = retry
                    end
                    if retry.attempts < MAX_ITEM_LOAD_RETRIES then
                        retry.attempts = retry.attempts + 1
                        QueueRefreshWhenItemLoaded(bag, slot)
                    end
                elseif eligible then
                    local itemLevel = 0
                    if C_Item and C_Item.GetDetailedItemLevelInfo then
                        itemLevel = C_Item.GetDetailedItemLevelInfo(link) or 0
                    elseif GetDetailedItemLevelInfo then
                        itemLevel = GetDetailedItemLevelInfo(link) or 0
                    end

                    local key = ComputeItemKey(bag, slot, link)
                    local bound = info.isBound
                    if IsSecretValue(bound) then bound = nil end
                    if IsSecretValue(bindType) then bindType = nil end
                    local auctionable
                    if bound == true or bindType == BIND_ON_ACQUIRE or bindType == BIND_ACCOUNT
                        or bindType == BIND_BNET or bindType == BIND_BNET_UNTIL_EQUIP then
                        auctionable = false
                    elseif bound == false and (bindType == 0 or bindType == BIND_ON_EQUIP or bindType == BIND_ON_USE) then
                        auctionable = true
                    end
                    local entry = {
                        bag = bag,
                        slot = slot,
                        key = key,
                        link = link,
                        texture = info.iconFileID or itemTexture or 134400,
                        quality = itemQuality,
                        count = info.stackCount or 1,
                        name = GetDisplayName(itemName, link),
                        itemLevel = itemLevel,
                        vendorPrice = vendorPrice,
                        auctionable = auctionable,
                        isSet = (setID ~= nil and setID ~= 0) or nil,
                        -- These materials may be needed for quests; require explicit selection.
                        manualOnly = activeMode.key == "disenchant" and IsForeverDisenchantMaterial(link),
                    }
                    entry.disenchantBlocked = activeMode.key == "disenchant" and ns.IsDisenchantBlocked(entry)
                    entry.excluded = IsBlacklistedItem(link)

                    -- Value data for the surface (nil when the guard is off /
                    -- no price known). isValuable is derived once here so the
                    -- surface can read a plain bool; the auto-queue guard uses
                    -- the same IsValuableItem, so they never disagree.
                    entry.priceCopper, entry.priceSource = LookupItemValue(link)
                    entry.isValuable = IsValuableItem(entry)

                    local tagText = GetBindTagText(bindType, bound)
                    if entry.isSet then
                        tagText = (tagText and (tagText .. " ") or "") .. "|cffff7f00SET|r"
                    end
                    entry.bindTag = tagText

                    items[#items + 1] = entry
                    validKeys[entry.key] = not entry.disenchantBlocked and not entry.excluded
                end
            else
                itemLoadRetries[bag .. ":" .. slot] = nil
            end
        end
    end

    for key in pairs(selected) do
        if not validKeys[key] then
            selected[key] = nil
        end
    end

    ns.waitingForItems = waiting
    SortItems()
    BuildQueue()
end

local function UpdateStatusText()
    if not statusText then
        return
    end

    if not activeMode.isKnown() then
        statusText:SetText(L[activeMode.notLearnedTextKey or "STATUS_NOT_LEARNED"] or L["STATUS_NOT_LEARNED"])
        return
    end

    if InCombatLockdown() then
        statusText:SetText(L["STATUS_IN_COMBAT"])
        return
    end

    if bulkMessage then
        statusText:SetText(bulkMessage)
    elseif #items == 0 and (ns.waitingForItems or 0) > 0 then
        statusText:SetText(string.format(L["WAITING_FOR_ITEMS"], ns.waitingForItems))
    else
        statusText:SetText(string.format(L["FOUND_COUNT"], #items))
    end
end

local function PreviewForItem(item)
    if not item or item.disenchantBlocked or not ns.Prediction or not db or db.showExpected == false
        or not activeMode or activeMode.key ~= "disenchant" then return "" end
    local ok, text = pcall(function()
        return ns.Prediction.BuildPreview(ns.Prediction.Estimate(item))
    end)
    return ok and text or ""
end

local function ClearListRow(row)
    if GameTooltip:IsOwned(row) or (row.exclude and GameTooltip:IsOwned(row.exclude)) then GameTooltip:Hide() end
    row.item = nil
    row.icon:SetTexture(nil)
    row.icon:SetDesaturated(false)
    row.icon:SetVertexColor(1, 1, 1, 1)
    row.checkbox:SetChecked(false)
    row.label:SetText("")
    row.levelText:SetText("")
    if row.preview then row.preview:SetText("") end
    if row.bindText then
        row.bindText:SetText("")
    end
    if row.valueText then
        row.valueText:SetText("")
    end
    row:Hide()
end

local function SetListRowItem(row, item)
    if row.item ~= item and (GameTooltip:IsOwned(row) or GameTooltip:IsOwned(row.exclude)) then GameTooltip:Hide() end
    row.item = item
    if row.preview then row.preview:SetText(PreviewForItem(item)) end
    local blocked = item.disenchantBlocked == true or item.excluded == true
    local isSelected = not blocked and selected[item.key] == true
    if blocked then
        row:RegisterForClicks()
        row.highlight:Hide()
    else
        row:RegisterForClicks("LeftButtonUp")
    end
    row.checkbox:SetEnabled(not blocked)
    row.checkbox:EnableMouse(not blocked)

    row.icon:SetTexture(item.texture or 134400)
    if blocked then
        ns.SettingsTheme:PaintItemBorder(row.iconBorder.edge, item.quality, 0.46, 0.46, 0.46)
    else
        ns.SettingsTheme:PaintItemBorder(row.iconBorder.edge, item.quality)
    end
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon:SetDesaturated(blocked)
    row.icon:SetVertexColor(blocked and 0.55 or 1, blocked and 0.55 or 1, blocked and 0.55 or 1, 1)
    row.exclude:SetText(item.excluded and "+" or "x")
    ns.SettingsTheme:PaintButton(row.exclude, item.excluded == true)
    if row.preview then row.preview:SetAlpha(blocked and 0.6 or 1) end

    local countText = item.count and item.count > 1 and (" x" .. item.count) or ""
    local hasLevel = (item.itemLevel or 0) > 0
    row.label:SetText((item.name or L["UNKNOWN"]) .. (hasLevel and "" or countText))
    row.levelText:SetText(hasLevel and string.format(L["ITEM_LEVEL"], item.itemLevel, countText) or "")
    local levelShade = blocked and 0.62 or 0.85
    row.levelText:SetTextColor(levelShade, levelShade, levelShade)
    row.levelText:SetShown(hasLevel)

    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[item.quality]
    if blocked then
        row.label:SetTextColor(0.62, 0.62, 0.62)
    elseif color then
        row.label:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
    else
        row.label:SetTextColor(1, 1, 1)
    end

    if row.bindText then
        local bindText = activeMode.usesItemProtection and (item.bindTag or "") or ""
        row.bindText:SetText(blocked and StripColorCodes(bindText) or bindText)
        local bindShade = blocked and 0.62 or 1
        row.bindText:SetTextColor(bindShade, bindShade, bindShade)
        row.bindText:SetWidth(math.max(1, math.ceil(row.bindText:GetStringWidth())))
    end
    if row.valueText then
        local hasValue = not blocked and item.isValuable and item.priceCopper and ns.Prices and ns.Prices.FormatGoldIcon
        if hasValue then
            -- Coin icon + amount (no "VALUE/WERT" label) - Oliver's design call.
            row.valueText:SetText(ns.Prices.FormatGoldIcon(item.priceCopper))
            row.valueText:SetWidth(math.max(1, math.min(112, math.ceil(row.valueText:GetStringWidth()))))
        else
            row.valueText:SetText("")
        end
        local trailing = hasValue and row.valueText or row.bindText
        row.levelText:ClearAllPoints()
        row.levelText:SetPoint("RIGHT", trailing, "LEFT", -6, 0)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", row.iconBorder, "RIGHT", 8, row.titleOffset or 8)
        row.label:SetPoint("RIGHT", hasLevel and row.levelText or trailing, "LEFT", -4, 0)
    end

    row.checkbox:SetChecked(isSelected)
    row:Show()
end

-- Changing the queue refreshes the secure cast button and panel layout.
local function SetItemSelected(item, checked)
    if not item or item.disenchantBlocked or item.excluded or IsBlacklistedItem(item.link) then
        return
    end
    if InCombatLockdown() then
        Print(L["NOT_IN_COMBAT"])
        return
    end
    bulkMessage = nil
    selected[item.key] = checked or nil
    BuildQueue()
    if mainFrame then
        mainFrame:RefreshUI()
    end
end

local function ToggleRowSelection(item)
    if item then
        SetItemSelected(item, not selected[item.key])
    end
end

local function CreateListRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row.band = ns.SettingsTheme:RowBand(row)
    local highlight = ns.SettingsTheme:MenuHighlight(row)
    row.highlight = highlight

    local checkbox = ns.Style.CheckButton(row, 22)
    checkbox:SetPoint("LEFT", 0, 0)
    row.checkbox = checkbox

    local exclude = ns.Style.Button(row)
    exclude:SetSize(22, 22)
    exclude:SetPoint("LEFT", checkbox, "RIGHT", 5, 0)
    exclude:SetScript("OnClick", function()
        local item = row.item
        if not item then return end
        if InCombatLockdown() then Print(L["NOT_IN_COMBAT"]); return end
        if GetBagItemLinkSafe(item.bag, item.slot) ~= item.link
            or ComputeItemKey(item.bag, item.slot, item.link) ~= item.key then
            RefreshList()
            return
        end
        ns.ToggleItemExclusion(item)
    end)
    exclude:HookScript("OnEnter", function(self)
        if not row.item then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L[row.item.excluded and "INCLUDE_ITEM" or "EXCLUDE_ITEM"])
        GameTooltip:Show()
    end)
    exclude:HookScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    exclude:HookScript("OnHide", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    row.exclude = exclude

    local iconBorder = CreateIconBorder(row, 24)
    iconBorder:SetPoint("LEFT", exclude, "RIGHT", 7, 0)
    iconBorder:SetFrameLevel(row:GetFrameLevel() + 1)
    row.iconBorder = iconBorder

    row.icon = iconBorder.itemIcon

    local bindText = ns.InterfaceFonts:CreateText(row, "OVERLAY", "GameFontNormalSmall", db)
    bindText:SetPoint("RIGHT", row, "RIGHT", -8, 8)
    bindText:SetWidth(56)
    bindText:SetHeight(18)
    bindText:SetJustifyH("RIGHT")
    row.bindText = bindText

    local valueText = ns.InterfaceFonts:CreateText(row, "OVERLAY", "GameFontNormalSmall", db)
    valueText:SetPoint("RIGHT", bindText, "LEFT", -6, 0)
    valueText:SetWidth(112)
    valueText:SetHeight(18)
    valueText:SetJustifyH("RIGHT")
    valueText:SetTextColor(1, 0.82, 0)
    row.valueText = valueText

    local label = ns.InterfaceFonts:CreateText(row, "OVERLAY", "GameFontNormal", db)
    label:SetPoint("LEFT", iconBorder, "RIGHT", 8, 8)
    label:SetPoint("RIGHT", valueText, "LEFT", -4, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetHeight(18)
    row.label = label
    local levelText = ns.InterfaceFonts:CreateText(row, "OVERLAY", "GameFontNormalSmall", db)
    levelText:SetTextColor(0.85, 0.85, 0.85)
    levelText:SetWordWrap(false)
    levelText:SetHeight(18)
    row.levelText = levelText

    local preview = ns.InterfaceFonts:CreateText(row, "OVERLAY", "GameFontNormalSmall", db)
    preview:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)
    preview:SetPoint("TOPRIGHT", row, "RIGHT", -8, -3)
    preview:SetHeight(20)
    preview:SetJustifyH("LEFT")
    preview:SetWordWrap(false)
    preview:SetTextColor(0.75, 0.8, 0.9)
    row.preview = preview

    checkbox:SetScript("OnClick", function(self)
        local parentRow = self:GetParent()
        ToggleRowSelection(parentRow and parentRow.item)
        -- Undo the checkbox's own visual toggle if the selection was refused
        -- (in combat) - the refresh below re-syncs it either way.
        if parentRow and parentRow.item then
            self:SetChecked(selected[parentRow.item.key] == true)
        end
    end)

    row:SetScript("OnClick", function(self)
        ToggleRowSelection(self.item)
    end)

    row:SetScript("OnEnter", function(self)
        if not self.item then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetBagItem(self.item.bag, self.item.slot)
        if self.item.excluded then
            GameTooltip:AddLine(L["EXCLUDED_ITEM"], 0.8, 0.8, 0.8, true)
        end
        if self.item.disenchantBlocked then
            GameTooltip:AddLine(L["CANNOT_DISENCHANT_ITEM"], 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
            return
        end
        highlight:Show()
        if self.item.isValuable and self.item.priceCopper and self.item.priceSource
            and ns.Prices and ns.Prices.FormatGold then
            GameTooltip:AddLine(string.format(L["VALUE_TOOLTIP"],
                ns.Prices.FormatGold(self.item.priceCopper), self.item.priceSource), 1, 0.82, 0)
        end
        if ns.Prediction and activeMode and activeMode.key == "disenchant" and db and db.showExpected ~= false then
            ns.Prediction.AppendToTooltip(GameTooltip, self.item)
        end
        GameTooltip:Show()
    end)

    row:SetScript("OnLeave", function()
        highlight:Hide()
        GameTooltip:Hide()
    end)
    row:HookScript("OnHide", function() highlight:Hide() end)

    row:Hide()
    return row
end

local function CreateQueueRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(24)

    local iconBorder = CreateIconBorder(row, 20)
    iconBorder:SetPoint("LEFT", 0, 0)
    row.iconBorder = iconBorder

    row.icon = iconBorder.itemIcon

    local label = ns.InterfaceFonts:CreateText(row, "OVERLAY", "GameFontNormalSmall", db)
    label:SetPoint("LEFT", iconBorder, "RIGHT", 6, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -64, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    row.label = label

    local removeButton = ns.Style.Button(row)
    row.removeButton = removeButton
    removeButton:SetSize(56, 20)
    removeButton:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    removeButton:SetText(L["DELETE"])
    removeButton:SetScript("OnClick", function()
        SetItemSelected(row.item, false)
    end)

    row:Hide()
    return row
end

local RequestRowsRefresh
local rowsRevision = 0

local function CreateRowsViewport(parent)
    -- Like Vendor's item pages, rows live directly in a fixed-size viewport.
    local view = CreateFrame("Frame", nil, parent)
    view:SetClipsChildren(true)
    view.offset, view.range = 0, 0
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetValueStep(1)
    bar:SetObeyStepOnDrag(true)
    bar:SetWidth(9)
    bar:SetPoint("TOPLEFT", view, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", view, "BOTTOMRIGHT", 4, 0)
    ns.SettingsTheme:SkinScrollBar(bar, 6, 28)
    view.bar = bar
    local syncing

    function view:SetOffset(value)
        if InCombatLockdown() then return end
        value = math.max(0, math.min(self.range, math.floor(value + .5)))
        if self.offset == value then return end
        self.offset = value
        RequestRowsRefresh()
    end

    function view:VisibleRange(count, rowHeight, spacing)
        local width, height = self:GetWidth(), self:GetHeight()
        if not width or not height or width <= 0 or height <= 0 then return end
        local capacity = math.max(0, math.floor((height + spacing) / (rowHeight + spacing)))
        self.range = math.max(0, count - capacity)
        self.offset = math.max(0, math.min(self.range, self.offset))
        syncing = true
        bar:SetMinMaxValues(0, self.range)
        bar:SetValue(self.offset)
        syncing = nil
        local scrollable = capacity > 0 and self.range > 0 and self:IsVisible()
        bar:SetShown(scrollable)
        bar:EnableMouse(scrollable)
        return self.offset, math.min(capacity, count - self.offset), math.max(1, math.floor(width))
    end

    bar:SetScript("OnValueChanged", function(_, value)
        if not syncing then view:SetOffset(value) end
    end)
    view:EnableMouseWheel(true)
    view:SetScript("OnMouseWheel", function(_, delta) view:SetOffset(view.offset - delta * 3) end)
    view:HookScript("OnSizeChanged", function() RequestRowsRefresh() end)
    view:HookScript("OnShow", function() RequestRowsRefresh() end)
    view:HookScript("OnHide", function() bar:Hide() end)
    bar:Hide()
    return view
end

local function PositionVisibleRow(row, view, slot, width, height, spacing)
    local y = -(slot - 1) * (height + spacing)
    if row.layoutY ~= y then
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", view, "TOPLEFT", 0, y)
        row.layoutY = y
    end
    if row.layoutHeight ~= height then
        row:SetHeight(height)
        row.layoutHeight = height
        if row.preview then
            row.titleOffset = height > ROW_HEIGHT and 8 or 0
            row.checkbox:ClearAllPoints()
            row.checkbox:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -(height - 22) / 2)
            row.bindText:ClearAllPoints()
            row.bindText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -height / 2 + row.titleOffset + 9)
            row.label:SetPoint("LEFT", row.iconBorder, "RIGHT", 8, row.titleOffset)
            row.preview:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -height / 2 + row.titleOffset - 11)
        else
            row.iconBorder:ClearAllPoints()
            row.iconBorder:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -(height - 20) / 2)
        end
    end
    if row.layoutWidth ~= width then
        row:SetWidth(width)
        row.layoutWidth = width
    end
end

local function UpdateListRows()
    if not listScrollFrame or not listScrollFrame:IsVisible() then return end
    local height = activeMode.key == "disenchant" and db.showExpected ~= false and 54 or ROW_HEIGHT
    local offset, visible, width = listScrollFrame:VisibleRange(#items, height, ROW_SPACING)
    if not offset then return end
    local empty = listScrollFrame.empty
    if empty then
        local message
        if (ns.waitingForItems or 0) > 0 then
            message = string.format(L["WAITING_FOR_ITEMS"], ns.waitingForItems)
        else
            message = L[activeMode.emptyTextKey or "COMPACT_EMPTY"]
        end
        empty:SetText(message)
        empty:SetShown(#items == 0)
    end

    for slot = 1, visible do
        local index = offset + slot
        local item = items[index]
        local row = listRows[slot]
        if not row then
            row = CreateListRow(listScrollFrame)
            listRows[slot] = row
        end
        PositionVisibleRow(row, listScrollFrame, slot, width, height, ROW_SPACING)
        if row.item ~= item or row.dataRevision ~= rowsRevision then
            row.band:SetShown(index % 2 == 1)
            SetListRowItem(row, item)
            row.dataRevision = rowsRevision
        end
    end
    for slot = visible + 1, #listRows do
        if listRows[slot].item then ClearListRow(listRows[slot]) end
    end
end

local function UpdateQueueRows()
    if not queueScrollFrame or not queueScrollFrame:IsVisible() then return end
    local offset, visible, width = queueScrollFrame:VisibleRange(#queue, 24, 2)
    if not offset then return end
    for slot = 1, visible do
        local index = offset + slot
        local item = queue[index]
        local row = queueRows[slot]
        if not row then
            row = CreateQueueRow(queueScrollFrame)
            queueRows[slot] = row
        end
        PositionVisibleRow(row, queueScrollFrame, slot, width, 24, 2)
        if row.item ~= item or row.dataRevision ~= rowsRevision or row.queueIndex ~= index then
            row.item, row.queueIndex, row.dataRevision = item, index, rowsRevision
            row.icon:SetTexture(item.texture or 134400)
            ns.SettingsTheme:PaintItemBorder(row.iconBorder.edge, item.quality)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.label:SetText(index .. ". " .. (item.name or L["UNKNOWN"]))
            if index == 1 then row.label:SetTextColor(1, 0.82, 0)
            else row.label:SetTextColor(0.9, 0.9, 0.9) end
            row:Show()
        end
    end
    for slot = visible + 1, #queueRows do
        if queueRows[slot].item then
            queueRows[slot].item = nil
            queueRows[slot]:Hide()
        end
    end
end

local rowsRefreshQueued = false
RequestRowsRefresh = function(refreshData)
    if refreshData == true then rowsRevision = rowsRevision + 1 end
    if rowsRefreshQueued then return end
    rowsRefreshQueued = true
    -- Frame dimensions can still be unresolved when Show or anchor changes return.
    C_Timer.After(0, function()
        rowsRefreshQueued = false
        if InCombatLockdown() then
            needsRefreshAfterCombat = true
            return
        end
        UpdateListRows()
        UpdateQueueRows()
    end)
end

local function ClassifyDisenchantFailure(message, errorName)
    if errorName == "ERR_CANT_BE_DISENCHANTED" or errorName == "SPELL_FAILED_CANT_BE_DISENCHANTED" then
        return "hard"
    end
    if errorName == "ERR_INVALID_ITEM_TARGET" or errorName == "SPELL_FAILED_BAD_TARGETS" then
        return "generic"
    end
    if IsSecretValue(message) or type(message) ~= "string" or message == "" then
        return nil
    end

    local cleaned = string.lower(StripColorCodes(message))
    local cantBeDisenchanted = type(ERR_CANT_BE_DISENCHANTED) == "string" and string.lower(ERR_CANT_BE_DISENCHANTED) or nil
    local spellCannotDisenchant = type(SPELL_FAILED_CANT_BE_DISENCHANTED) == "string"
        and string.lower(SPELL_FAILED_CANT_BE_DISENCHANTED) or nil
    local invalidItemTarget = type(ERR_INVALID_ITEM_TARGET) == "string" and string.lower(ERR_INVALID_ITEM_TARGET) or nil

    if cleaned == cantBeDisenchanted or cleaned == spellCannotDisenchant then
        return "hard"
    end

    if invalidItemTarget and cleaned == invalidItemTarget then
        return "generic"
    end

    if cleaned:find("cannot be disenchanted", 1, true) or cleaned:find("can not be disenchanted", 1, true) then
        return "hard"
    end

    if cleaned:find("not a valid target", 1, true) or cleaned:find("invalid target", 1, true) then
        return "generic"
    end

    if cleaned:find("kein gültiges ziel", 1, true) or cleaned:find("ungueltiges ziel", 1, true) or cleaned:find("ungültiges ziel", 1, true) then
        return "generic"
    end

    if cleaned:find("kann nicht entzaubert werden", 1, true) then
        return "hard"
    end

    return nil
end

-- ===================================================================
-- Processing modes (1.6.0)
-- ===================================================================
-- Disenchanting, milling and prospecting are all "bag-target" casts that share
-- this engine: a secure cast on a bag slot, driven by the same scan -> queue ->
-- arm -> BAG_UPDATE -> rescan loop. A mode descriptor captures the only things
-- that differ per mode, so the engine stays a single code path while each client
-- exposes only the profession abilities it actually supports.
--
-- Descriptor fields:
--   key                stable id (DB and per-mode blacklist namespace)
--   spellID            the bag-target spell to cast
--   minStack           units one cast needs in a single slot (DE 1, mill/prosp 5)
--   usesItemProtection value/set/ilvl/binding protection applies? (DE only)
--   buttonTextKey/countTextKey  locale keys for the cast button
--   spellName()/icon() live lookups for the secure "spell" attribute and the icon
--   isAvailable()      spell exists on THIS client (hides unsupported modes)
--   isKnown()          the character currently knows the ability
--   scanEligible(link, quality, info)  mode-intrinsic eligibility for one slot
--   classifyFailure(msg)  map an error line to hard/generic/nil for the blacklist
local DISENCHANT_MODE = {
    key                = "disenchant",
    spellID            = SPELL_ID_DISENCHANT,
    minStack           = 1,
    usesItemProtection = true,
    buttonTextKey      = "DISENCHANT",
    countTextKey       = "DISENCHANT_COUNT",
    modeNameKey        = "MODE_DISENCHANT",
    emptyTextKey       = "COMPACT_EMPTY",
    notLearnedTextKey  = "STATUS_NOT_LEARNED",
    queueNotLearnedKey = "QUEUE_NOT_LEARNED",
    blacklistHintKey   = "COMPACT_BLACKLIST_HINT",
    -- Compact-bar queue line (Sol's request: the surface reads this instead of
    -- branching on mode.key). Disenchant keeps the existing COMPACT_QUEUE string.
    queueTextKey       = "COMPACT_QUEUE",
    spellName          = function() return GetSpellNameSafe(SPELL_ID_DISENCHANT) end,
    icon               = function() return GetSpellTextureSafe(SPELL_ID_DISENCHANT) end,
    isAvailable        = function() return GetSpellNameSafe(SPELL_ID_DISENCHANT) ~= nil end,
    isKnown            = PlayerKnowsDisenchant,
    scanEligible       = function(itemLink, itemQuality)
        -- Keep the quality filter for equipment and explicit Forever exceptions.
        return IsReasonablyDisenchantable(itemLink, itemQuality) and IsQualityEnabled(itemQuality)
    end,
    classifyFailure    = ClassifyDisenchantFailure,
}

-- Milling and prospecting share the disenchant engine (bag-target cast, 5 units
-- per cast). usesItemProtection = false keeps value/set/ilvl protection out.
-- Every visible surface string is selected by the descriptor, so the shared UI
-- never needs to branch on mode.key.
local MILLING_MODE = {
    key                = "milling",
    spellID            = SPELL_ID_MILLING,
    minStack           = 5,
    usesItemProtection = false,
    buttonTextKey      = "MILL",
    countTextKey       = "MILL_COUNT",
    modeNameKey        = "MODE_MILLING",
    emptyTextKey       = "COMPACT_EMPTY_MILLING",
    notLearnedTextKey  = "MODE_NOT_LEARNED_HINT",
    queueNotLearnedKey = "MODE_NOT_LEARNED_HINT",
    blacklistHintKey   = "COMPACT_BLACKLIST_HINT_MILLING",
    queueTextKey       = "COMPACT_QUEUE_MILLING",
    spellName          = function() return GetSpellNameSafe(SPELL_ID_MILLING) end,
    icon               = function() return GetSpellTextureSafe(SPELL_ID_MILLING) end,
    isAvailable        = function() return IS_NON_RETAIL_CLIENT and GetSpellNameSafe(SPELL_ID_MILLING) ~= nil end,
    isKnown            = function() return PlayerKnowsSpellID(SPELL_ID_MILLING) end,
    scanEligible       = function(itemLink) return IsMillableHerb(itemLink) end,
    classifyFailure    = function() return nil end,  -- FIRST CUT: never auto-blacklist materials
}

local PROSPECTING_MODE = {
    key                = "prospecting",
    spellID            = SPELL_ID_PROSPECTING,
    minStack           = 5,
    usesItemProtection = false,
    buttonTextKey      = "PROSPECT",
    countTextKey       = "PROSPECT_COUNT",
    modeNameKey        = "MODE_PROSPECTING",
    emptyTextKey       = "COMPACT_EMPTY_PROSPECTING",
    notLearnedTextKey  = "MODE_NOT_LEARNED_HINT",
    queueNotLearnedKey = "MODE_NOT_LEARNED_HINT",
    blacklistHintKey   = "COMPACT_BLACKLIST_HINT_PROSPECTING",
    queueTextKey       = "COMPACT_QUEUE_PROSPECTING",
    spellName          = function() return GetSpellNameSafe(SPELL_ID_PROSPECTING) end,
    icon               = function() return GetSpellTextureSafe(SPELL_ID_PROSPECTING) end,
    isAvailable        = function() return IS_NON_RETAIL_CLIENT and GetSpellNameSafe(SPELL_ID_PROSPECTING) ~= nil end,
    isKnown            = function() return PlayerKnowsSpellID(SPELL_ID_PROSPECTING) end,
    scanEligible       = function(itemLink) return IsProspectableOre(itemLink) end,
    classifyFailure    = function() return nil end,  -- FIRST CUT: never auto-blacklist materials
}

ns.Modes = {
    list    = { DISENCHANT_MODE, MILLING_MODE, PROSPECTING_MODE },
    byKey   = { disenchant = DISENCHANT_MODE, milling = MILLING_MODE, prospecting = PROSPECTING_MODE },
    default = DISENCHANT_MODE,
}

local function IsModeAvailable(mode)
    return mode and (not mode.isAvailable or mode.isAvailable())
end

local function GetAvailableModes()
    local available = {}
    for _, mode in ipairs(ns.Modes.list) do
        if IsModeAvailable(mode) then
            available[#available + 1] = mode
        end
    end
    return available
end

local function ResolveMode(modeKey)
    local mode = modeKey and ns.Modes.byKey[modeKey]
    -- Stored keys can outlive a client or profession. Prefer the configured
    -- default when available, then fall back to the first client-valid mode.
    if not IsModeAvailable(mode) then
        mode = IsModeAvailable(ns.Modes.default) and ns.Modes.default or GetAvailableModes()[1]
    end
    return mode or ns.Modes.default
end

-- Pure setter: select the mode and remember it. No combat guard and no refresh -
-- used at load (ADDON_LOADED), before the frames and queue exist.
local function ApplyMode(modeKey)
    activeMode = ResolveMode(modeKey)
    if db then
        db.activeMode = activeMode.key
    end
    UpdateBindingName(activeMode.buttonTextKey)
    return activeMode
end

-- User-facing switch (the surface calls ns.Modes.SetActive). Changing the mode
-- rebuilds the secure cast button for a different spell, which is protected in
-- combat - so it politely refuses during lockdown (the single combat guard for
-- switching). Out of combat it applies the mode, drops the manual selection and
-- rescans, so the queue and armed target belong to the new mode.
local function SetActiveMode(modeKey)
    if InCombatLockdown() then
        Print(L["MODE_CHANGE_IN_COMBAT"] or L["NOT_IN_COMBAT"])
        return activeMode, false
    end
    local requestedMode = ns.Modes.byKey[modeKey]
    if not IsModeAvailable(requestedMode) then
        return activeMode, false
    end
    if requestedMode == activeMode then
        return activeMode, true
    end
    -- A delayed failure from the previous spell must never be classified or
    -- blacklisted under the newly selected mode.
    ClearPendingDisenchant()
    nextAllowedQueueClickAt = 0
    ApplyMode(modeKey)
    bulkMessage = nil
    wipe(selected)
    if RefreshList then
        RefreshList()
    end
    -- The blacklist window is per-mode now; if it is open, show the new mode's list.
    if blacklistFrame and blacklistFrame:IsShown() and RefreshBlacklistUI then
        RefreshBlacklistUI()
    end
    return activeMode, true
end

-- Safe default until EnsureDB + ApplyMode run in ADDON_LOADED.
activeMode = ns.Modes.default
ns.Modes.GetActive = function() return activeMode end
ns.Modes.GetAvailable = GetAvailableModes
ns.Modes.SetActive = SetActiveMode


local function ExtractMessageFromEventArgs(...)
    local numArgs = select("#", ...)
    for i = numArgs, 1, -1 do
        local value = select(i, ...)
        if not IsSecretValue(value) and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

local function AddItemToBlacklist(item)
    if InCombatLockdown() then Print(L["NOT_IN_COMBAT"]); return end
    if not item or not db or not db.blacklist then
        return
    end

    local blacklistKey = GetBlacklistKeyFromLink(item.link)
    if not blacklistKey then return end
    GetModeBlacklist()[blacklistKey] = true

    for _, candidate in ipairs(items) do
        if GetBlacklistKeyFromLink(candidate.link) == blacklistKey then
            selected[candidate.key] = nil
        end
    end

    if not RefreshList() then return end
    if blacklistFrame and blacklistFrame:IsShown() and RefreshBlacklistUI then
        RefreshBlacklistUI()
    end
end

function ns.ToggleItemExclusion(item)
    if not item or not db or InCombatLockdown() then return end
    local key = GetBlacklistKeyFromLink(item.link)
    if not key then return end
    if GetModeBlacklist()[key] then
        GetModeBlacklist()[key] = nil
        RefreshList()
        if blacklistFrame and blacklistFrame:IsShown() and RefreshBlacklistUI then RefreshBlacklistUI() end
    else
        AddItemToBlacklist(item)
    end
end

local function MarkCannotDisenchant(item)
    disenchantBlocked[item.key] = item.link
    if activeMode.key ~= "disenchant" then return end
    selected[item.key] = nil
    Print(string.format(L["DISENCHANT_BLOCKED"], item.name))
    RefreshList()
end

local function ResolvePendingDisenchant()
    local item = pendingDisenchantItem
    if not item or item.resolving then return end

    item.resolving = true
    -- STOP can precede SUCCEEDED, and the reason can arrive after FAILED.
    C_Timer.After(0.2, function()
        if pendingDisenchantItem ~= item then return end
        ClearPendingDisenchant()
        if InCombatLockdown() then
            needsRefreshAfterCombat = true
            return
        end

        local bag, slot = FindPendingBagLocation(item)
        if bag ~= nil then
            local blocked = item.refused or TooltipSaysCantDisenchant({ bag = bag, slot = slot, link = item.link })
            if blocked then
                MarkCannotDisenchant(item)
                return
            end
            if item.reason then
                Print(string.format(L["DISENCHANT_FAILED_REASON"], item.name, item.reason))
            else
                Print(string.format(L["DISENCHANT_FAILED"], item.name))
            end
        end
        RefreshList()
    end)
end


local function UpdateQueueButtonVisual(label)
    if not queueButton then
        return
    end

    if queueButtonText then
        queueButtonText:SetText(label or L["DISENCHANT"])
    end
    ns.Style.PaintButton(queueButton)
end

local function ClearQueueButtonAttributes()
    if not queueButton then
        return
    end
    -- The secure state driver disarms the button during combat.
    if InCombatLockdown() then
        return
    end

    queueButton:SetAttribute("type", nil)
    queueButton:SetAttribute("spell", nil)
    queueButton:SetAttribute("target-item", nil)
    queueButton:SetAttribute("target-bag", nil)
    queueButton:SetAttribute("target-slot", nil)
end

-- Fire the secure action exactly ONCE per click: register only the click edge
-- the client actually acts on (the "cast on key down" CVar). This replaces the
-- old timer workaround - with both edges registered plus a plain "type"
-- attribute, the cast used to fire twice per click.
local function UpdateQueueButtonClickRegistration()
    if not queueButton or InCombatLockdown() then
        return
    end
    if not queueButton.combatDriver and RegisterStateDriver then
        queueButton:SetAttribute("_onstate-sdecombat", [[
            if newstate == "locked" then self:SetAttribute("type", nil) end
        ]])
        RegisterStateDriver(queueButton, "sdecombat", "[combat] locked; open")
        queueButton.combatDriver = true
    end
    -- Remember which edge we registered: WoW has no "GetRegisteredClicks",
    -- so the self-check needs this note to compare against the live CVar.
    if GetCVarBool and GetCVarBool("ActionButtonUseKeyDown") then
        queueButton:RegisterForClicks("AnyDown")
        queueButton.dehClickEdge = "AnyDown"
    else
        queueButton:RegisterForClicks("AnyUp")
        queueButton.dehClickEdge = "AnyUp"
    end
end

local function UpdateQueueButton()
    if not queueButton then
        return
    end

    local label = #queue > 1 and string.format(L[activeMode.countTextKey], #queue) or L[activeMode.buttonTextKey]

    -- One disarm path for all three "cannot cast right now" cases below -
    -- the sequence was copy-pasted three times before and only differed in
    -- the label and the explanatory info text.
    local function Disarm(buttonLabel, infoText)
        queueButton:Disable()
        ClearQueueButtonAttributes()
        UpdateQueueButtonVisual(buttonLabel)
        if queueInfoText then
            queueInfoText:SetText(infoText)
        end
    end

    if InCombatLockdown() then
        -- The state driver disarms the button until the queue can be checked again.
        return
    end

    if not activeMode.isKnown() then
        Disarm(label, L[activeMode.queueNotLearnedKey or "QUEUE_NOT_LEARNED"] or L["QUEUE_NOT_LEARNED"])
        return
    end

    local item = queue[1]
    if not item then
        Disarm(L[activeMode.buttonTextKey], L["QUEUE_EMPTY"])
        return
    end

    local spell = activeMode.spellName() or activeMode.spellID
    local targetItem = string.format("%d %d", item.bag, item.slot)

    ClearQueueButtonAttributes()
    UpdateQueueButtonClickRegistration()
    if not queueButton.combatDriver then
        Disarm(label, L["QUEUE_EMPTY"])
        return
    end
    -- Plain "type" - the mechanism the 1.3 line has proven in the field.
    -- Single-fire is guaranteed by the click registration above, not by a
    -- release-only attribute (typerelease silently did nothing on some clients).
    queueButton:SetAttribute("type", "spell")
    queueButton:SetAttribute("spell", spell)
    queueButton:SetAttribute("target-item", targetItem)
    queueButton:SetAttribute("target-bag", item.bag)
    queueButton:SetAttribute("target-slot", item.slot)
    queueButton:Enable()
    UpdateQueueButtonVisual(label)

    if queueInfoText then
        queueInfoText:SetText(string.format(L["QUEUE_NEXT"], item.name or L["UNKNOWN"]))
    end
end

function ns.ProfessionViews.SyncAction()
    if not (mainFrame.professionContent and queueButton) or InCombatLockdown() then return end
    if ns.ProfessionViews.current or #queue == 0 or not queuePanel:IsVisible() then
        if queueButton:IsShown() then queueButton:Hide() end
        return
    end
    local left, bottom = queuePanel:GetLeft(), queuePanel:GetBottom()
    if not left or not bottom then return end
    -- Copy the visible queue's geometry without making the Blizzard panel an
    -- anchor of a protected frame. Its position can change independently.
    local scale = queuePanel:GetEffectiveScale() / queueButton:GetEffectiveScale()
    local x, y = (left + queuePanel:GetWidth() - 16 - 122) * scale, (bottom + 12) * scale
    if x ~= queueButton.professionX or y ~= queueButton.professionY or scale ~= queueButton.professionScale then
        queueButton.professionX, queueButton.professionY, queueButton.professionScale = x, y, scale
        queueButton:ClearAllPoints()
        queueButton:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
        queueButton:SetSize(122 * scale, 24 * scale)
    end
    if not queueButton:IsShown() then queueButton:Show() end
end

local function UpdateLayout()
    if not mainFrame or not listPanel or not queuePanel then
        return
    end

    local topOffset = modeTabFrame and modeTabFrame:IsShown() and -67 or -44
    if not mainFrame.professionContent then topOffset = topOffset - 16 end
    local bottomInset = mainFrame.professionContent and 16 or 56
    local hasQueue = #queue > 0
    local layout = mainContent.listLayout
    if layout and layout.top == topOffset and layout.bottom == bottomInset and layout.hasQueue == hasQueue then
        ns.ProfessionViews.SyncAction()
        return
    end

    -- Replace individual anchors without temporarily collapsing the clipped viewports.
    queuePanel:SetPoint("TOPRIGHT", mainContent, "TOPRIGHT", -16, topOffset)
    queuePanel:SetPoint("BOTTOMRIGHT", mainContent, "BOTTOMRIGHT", -16, bottomInset)
    queuePanel:SetWidth(QUEUE_PANEL_WIDTH)

    listPanel:SetPoint("TOPLEFT", mainContent, "TOPLEFT", 16, topOffset)

    if hasQueue then
        queuePanel:Show()
        listPanel:SetPoint("BOTTOMRIGHT", queuePanel, "BOTTOMLEFT", -12, 0)
        mainContent.compactModeButton:ClearAllPoints()
        mainContent.compactModeButton:SetPoint("BOTTOMRIGHT", queuePanel, "BOTTOMRIGHT", -154, 12)
        mainContent.compactModeButton:Show()
    else
        listPanel:SetPoint("BOTTOMRIGHT", mainContent, "BOTTOMRIGHT", -16, bottomInset)
        queuePanel:Hide()
        mainContent.compactModeButton:Hide()
    end
    mainContent.listLayout = {top = topOffset, bottom = bottomInset, hasQueue = hasQueue}
    ns.ProfessionViews.SyncAction()
end

RefreshUI = function()
    if not mainFrame then
        return
    end

    if UpdateModeSurface then
        UpdateModeSurface()
    end

    -- queuePanel is an ancestor of the secure button, so Show/Hide/SetPoint on
    -- it are protected in combat (protection propagates to parents). Rows and
    -- texts are fine to update; the layout catches up after combat.
    if not InCombatLockdown() then
        UpdateLayout()
    end
    RequestRowsRefresh(true)
    UpdateStatusText()
    UpdateQueueButton()
    UpdateCompactFrame()
end

RefreshList = function()
    if InCombatLockdown() then
        needsRefreshAfterCombat = true
        UpdateStatusText()
        UpdateQueueButton()
        return false
    end

    bulkMessage = nil
    ScanBags()
    RefreshUI()
    return true
end

local function DockQueueButtonToCompact()
    if not queueButton or not compactFrame or not compactFullButton then
        return
    end
    if InCombatLockdown() then
        return
    end
    queueButton:SetParent(compactFrame)
    queueButton:ClearAllPoints()
    queueButton:SetPoint("RIGHT", compactFullButton, "LEFT", -6, 0)
    queueButton:SetSize(130, 24)
end

local function DockQueueButtonToPanel()
    if not queueButton or not queuePanel then
        return
    end
    if InCombatLockdown() then
        return
    end
    queueButton:SetParent(queuePanel)
    queueButton:ClearAllPoints()
    queueButton:SetPoint("BOTTOMRIGHT", queuePanel, "BOTTOMRIGHT", -16, 12)
    queueButton:SetSize(122, 24)
end

local function GetCompactSkippedText()
    local skipped = ns.GetValuableSkippedCount and ns.GetValuableSkippedCount() or 0
    if skipped == 1 then
        return L["COMPACT_SKIPPED_ONE"]
    elseif skipped > 1 then
        return string.format(L["COMPACT_SKIPPED_MANY"], skipped)
    end
    return nil
end

UpdateCompactFrame = function()
    if not compactFrame or not compactFrame:IsShown() then
        return
    end

    local item = queue[1]
    local skippedText = GetCompactSkippedText()
    compactFrame.currentItem = item
    local preview = PreviewForItem(item)
    if compactPreviewText then compactPreviewText:SetText(preview) end
    if item then
        compactIcon:SetTexture(item.texture or 134400)
        ns.SettingsTheme:PaintItemBorder(compactIcon:GetParent().edge, item.quality)
        compactIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local compactLabel = item.name or L["UNKNOWN"]
        if activeMode.usesItemProtection and item.bindTag then
            compactLabel = compactLabel .. "  " .. item.bindTag
        end
        compactNameText:SetText(compactLabel)

        local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[item.quality]
        if color then
            compactNameText:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
        else
            compactNameText:SetTextColor(1, 1, 1)
        end

        local nextItem = (item.count or 1) >= (activeMode.minStack or 1) * 2 and item or queue[2]
        local nextLabel = ""
        if nextItem then
            local name = nextItem.name or L["UNKNOWN"]
            local nextColor = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[nextItem.quality]
            if nextColor and nextColor.hex then name = nextColor.hex .. name .. "|r" end
            nextLabel = string.format(L["COMPACT_NEXT"],
                "|T" .. (nextItem.texture or 134400) .. ":16:16:0:0|t " .. name)
        end
        if skippedText then nextLabel = nextLabel ~= "" and (nextLabel .. "  |  " .. skippedText) or skippedText end
        compactQueueText:SetText(nextLabel)
    else
        compactIcon:SetTexture((activeMode.icon and activeMode.icon()) or 134400)
        ns.SettingsTheme:PaintItemBorder(compactIcon:GetParent().edge)
        compactIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        compactNameText:SetText(L[activeMode.emptyTextKey or "COMPACT_EMPTY"] or L["COMPACT_EMPTY"])
        compactNameText:SetTextColor(0.7, 0.7, 0.7)
        compactQueueText:SetText(skippedText or "")
    end

    local nameWidth = compactNameText:GetStringWidth() or 0
    local previewWidth = compactPreviewText and compactPreviewText:GetStringWidth() or 0
    local modeWidth = compactModeSelector and compactModeSelector:IsShown() and 98 or 0
    -- Compact owns a secure button: dimensions may only change out of combat.
    if not InCombatLockdown() then
        compactFrame:SetHeight((preview ~= "" or compactQueueText:GetText() ~= "") and 84 or 58)
        compactFrame:SetWidth(math.max(400 + modeWidth, math.min(620 + modeWidth,
            math.max(math.floor(nameWidth + 0.5) + 278 + modeWidth, previewWidth + 28))))
    end
end

SetCompactMode = function(enabled)
    if not compactFrame or not queueButton or not queuePanel then
        return
    end

    if InCombatLockdown() then
        Print(L["NOT_IN_COMBAT"])
        return
    end

    db.compactMode = enabled and true or false

    if enabled then
        if mainFrame then
            mainFrame:Hide()
        end
        DockQueueButtonToCompact()
        compactFrame:Show()
        RefreshList()
    else
        compactFrame:Hide()
        DockQueueButtonToPanel()
        if mainFrame then
            mainFrame:Show()
            if listScrollFrame then listScrollFrame:SetOffset(0) end
            RefreshList()
        end
    end
end

local function GetBlacklistEntries()
    local result = {}
    if not db or type(db.blacklist) ~= "table" then
        return result
    end

    for blacklistKey, isBlacklisted in pairs(GetModeBlacklist()) do
        if isBlacklisted then
            local itemRef
            if tostring(blacklistKey):match("^%d+$") then
                itemRef = "item:" .. tostring(blacklistKey)
            else
                itemRef = tostring(blacklistKey)
            end

            local itemName, itemLink, itemQuality, _, _, _, _, _, _, itemTexture = GetItemInfoSafe(itemRef)
            local displayName = GetDisplayName(itemName, itemLink or itemRef)
            if not displayName or displayName == "" or displayName == L["UNKNOWN_ITEM"] then
                displayName = tostring(blacklistKey)
            end

            result[#result + 1] = {
                key = blacklistKey,
                link = itemLink or itemRef,
                name = displayName,
                quality = itemQuality,
                texture = itemTexture or 134400,
            }
        end
    end

    table.sort(result, function(a, b)
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    return result
end

local function CreateBlacklistRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(26)

    local iconBorder = CreateIconBorder(row, 20)
    iconBorder:SetPoint("LEFT", 0, 0)
    row.iconBorder = iconBorder

    row.icon = iconBorder.itemIcon

    local label = ns.InterfaceFonts:CreateText(row, "OVERLAY", "GameFontNormalSmall", db)
    label:SetPoint("LEFT", iconBorder, "RIGHT", 6, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -70, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    row.label = label

    local removeButton = ns.Style.Button(row)
    removeButton:SetSize(56, 20)
    removeButton:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    removeButton:SetText(L["DELETE"])
    row.removeButton = removeButton

    removeButton:SetScript("OnClick", function(self)
        local row = self:GetParent()
        local entry = row.entry
        if not entry or not db or not db.blacklist then
            return
        end
        if GameTooltip:IsOwned(row) then
            GameTooltip:Hide()
        end
        GetModeBlacklist()[entry.key] = nil
        if RefreshBlacklistUI then
            RefreshBlacklistUI()
        end
        RefreshList()
    end)

    row:SetScript("OnEnter", function(self)
        if not self.entry or not self.entry.link then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.entry.link)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    row:Hide()
    return row
end

RefreshBlacklistUI = function()
    if not blacklistFrame or not blacklistScrollFrame or not blacklistScrollChild then
        return
    end

    local entries = GetBlacklistEntries()
    local width = math.max(100, (blacklistScrollFrame:GetWidth() or 0) - 24)
    local y = 0

    for index, entry in ipairs(entries) do
        local row = blacklistRows[index]
        if not row then
            row = CreateBlacklistRow(blacklistScrollChild)
            blacklistRows[index] = row
        end

        row.entry = entry
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", blacklistScrollChild, "TOPLEFT", 0, -y)
        row:SetWidth(width)
        row.icon:SetTexture(entry.texture or 134400)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.label:SetText(entry.name or L["UNKNOWN"])

        local color = entry.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[entry.quality]
        if color then
            row.label:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
        else
            row.label:SetTextColor(1, 1, 1)
        end
        ns.SettingsTheme:PaintItemBorder(row.iconBorder.edge, entry.quality)

        row:Show()
        y = y + 28
    end

    for index = #entries + 1, #blacklistRows do
        blacklistRows[index]:Hide()
    end

    if blacklistEmptyText then
        if #entries == 0 then
            blacklistEmptyText:Show()
        else
            blacklistEmptyText:Hide()
        end
    end

    blacklistScrollChild:SetSize(width, math.max(blacklistScrollFrame:GetHeight() or 1, y))
end

function ns.ProfessionViews.Restore()
    local current = ns.ProfessionViews.current
    if not current then return end
    ns.ProfessionViews.current = nil
    local frame = current.frame
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(UIParent)
    for _, point in ipairs(current.points) do frame:SetPoint(unpack(point, 1, 5)) end
    frame:SetSize(current.width, current.height)
    frame:SetFrameStrata(current.strata)
    frame:SetFrameLevel(current.level)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    ns.Style.Window(frame)
    frame.CloseButton:Show()
    frame.TitleBar:Show()
    ns.ProfessionViews.host:Hide()
    mainContent:Show()
    windowAppearance:ApplyTo(frame)
end

function ns.ProfessionViews.Open(frame)
    local page = ns.ProfessionViews.page
    if not page then return false end
    if InCombatLockdown() then return true end
    if ns.ProfessionViews.current and ns.ProfessionViews.current.frame == frame then return true end
    ns.ProfessionViews.Restore()
    local host = ns.ProfessionViews.host
    if not host then
        host = CreateFrame("Frame", nil, page)
        host:SetAllPoints(page)
        local back = ns.Style.Button(host)
        back:SetSize(145, 22)
        back:SetPoint("TOPLEFT", 16, -10)
        back:SetText(L["PROF_BACK"])
        back:SetScript("OnClick", function()
            if InCombatLockdown() then return end
            ns.ProfessionViews.Restore()
            RefreshUI()
        end)
        ns.ProfessionViews.host = host
    end
    local current = {frame = frame, width = frame:GetWidth(),
        height = frame:GetHeight(), level = frame:GetFrameLevel(), strata = frame:GetFrameStrata(), points = {}}
    for i = 1, frame:GetNumPoints() do current.points[i] = {frame:GetPoint(i)} end
    ns.ProfessionViews.current = current
    mainContent:Hide()
    queueButton:Hide()
    frame:Hide()
    if frame == settingsFrame then
        frame:SetScale(1)
        frame:SetAlpha(1)
    end
    frame:ClearAllPoints()
    frame:SetBackdrop(nil)
    frame:SetMovable(false)
    -- A scroll child must be able to move above the physical screen edge;
    -- the viewport, not the standalone window clamp, clips its contents.
    frame:SetClampedToScreen(false)
    frame.CloseButton:Hide()
    frame.TitleBar:Hide()
    host:Show()
    frame:SetParent(host)
    frame:SetPoint("TOPLEFT", 12, -40)
    frame:SetPoint("BOTTOMRIGHT", -12, 12)
    frame:SetFrameStrata(page:GetFrameStrata())
    frame:SetFrameLevel(host:GetFrameLevel() + 3)
    frame:Show()
    return true
end

ToggleBlacklistFrame = function()
    if not blacklistFrame then
        return
    end

    if ns.ProfessionViews.Open(blacklistFrame) then
        RefreshBlacklistUI()
        return
    end
    if blacklistFrame:IsShown() then
        blacklistFrame:Hide()
    else
        blacklistFrame:ClearAllPoints()
        if mainFrame and mainFrame:IsShown() then
            blacklistFrame:SetPoint("TOPLEFT", mainFrame, "TOPRIGHT", 20, -12)
        else
            blacklistFrame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
        end
        blacklistFrame:Show()
        blacklistFrame:Raise()
        RefreshBlacklistUI()
    end
end

local function ToggleMainFrame()
    -- Both windows can host the secure button, which makes Show/Hide on them
    -- protected while in combat - opening/closing must wait for combat to end.
    if InCombatLockdown() then
        Print(L["NOT_IN_COMBAT"])
        return
    end

    if db and db.compactMode and compactFrame then
        if compactFrame:IsShown() then
            compactFrame:Hide()
        else
            DockQueueButtonToCompact()
            compactFrame:Show()
            RefreshList()
        end
        return
    end

    if not mainFrame then
        return
    end

    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
        RefreshList()
    end
end

local function RaiseAddonWindows(clicked)
    local order = { mainFrame, settingsFrame, blacklistFrame }
    for _, frame in ipairs(order) do
        if frame and frame:IsShown() and frame ~= clicked then
            frame:Raise()
        end
    end
    if clicked and clicked ~= mainFrame and clicked:IsShown() then
        clicked:Raise()
    end
end

-- Builds a window in the slim, semi-transparent look of the compact bar:
-- custom backdrop, custom title bar (doubling as drag handle) and a close
-- button. The returned frame exposes .title (FontString), .TitleBar and
-- .CloseButton so other code can anchor to them.
local function CreateStyledWindow(globalName, width, height, extraTemplate, addonName)
    -- extraTemplate lets a caller mix in an additional frame template (e.g. the
    -- main window adds SecureHandlerStateTemplate so a state driver can hide it
    -- in combat). The default look/behaviour is unchanged for every other window.
    local template = "BackdropTemplate"
    if extraTemplate and extraTemplate ~= "" then
        template = template .. "," .. extraTemplate
    end
    local f = CreateFrame("Frame", globalName, UIParent, template)
    f:SetSize(width, height)
    ns.Style.Window(f)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    -- All addon windows share the normal strata like Blizzard windows;
    -- SetToplevel: the clicked window rises to the front automatically
    f:SetToplevel(true)
    f:SetScript("OnMouseDown", function(self)
        RaiseAddonWindows(self)
    end)

    local titleBar = Sintezza_Theme:CreateWidgets(ns.SettingsTheme):WindowHeader(f, {
        addonName = addonName,
        icon = Sintezza_Theme.icons.Sintezza_Disenchant,
        onClose = function()
            if InCombatLockdown() and f:IsProtected() then
                Print(L["NOT_IN_COMBAT"])
                return
            end
            f:Hide()
        end,
    })
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnMouseDown", function() RaiseAddonWindows(f) end)
    titleBar:SetScript("OnDragStart", function()
        if InCombatLockdown() or not f:IsMovable() then return end
        if (f == mainFrame or f == settingsFrame) and windowAppearance:Get("locked") then return end
        f:StartMoving()
    end)
    titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f.TitleBar, f.CloseButton, f.title = titleBar, titleBar.close, titleBar.title

    return f
end

local function GetModeName(mode)
    return (mode and mode.modeNameKey and L[mode.modeNameKey]) or (mode and mode.key) or L["UNKNOWN"]
end

local function SelectModeFromSurface(mode)
    if not mode or not ns.Modes or not ns.Modes.SetActive then
        return
    end
    ns.Modes.SetActive(mode.key)
end

local function CreateModeTabs()
    local theme = ns.SettingsTheme
    modeTabFrame = CreateFrame("Frame", nil, mainContent)
    modeTabFrame:SetPoint("TOPLEFT", mainContent, "TOPLEFT", 16, -53)
    modeTabFrame:SetHeight(24)

    local previous
    for _, mode in ipairs(GetAvailableModes()) do
        local button = ns.Style.Button(modeTabFrame)
        button:SetSize(118, 22)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 6, 0)
        else
            button:SetPoint("LEFT", modeTabFrame, "LEFT", 0, 0)
        end
        button:SetText(GetModeName(mode))
        theme:SkinTab(button)
        button.mode = mode
        button:SetScript("OnClick", function(self)
            SelectModeFromSurface(self.mode)
        end)
        button:SetScript("OnEnter", function(self)
            if self.mode and not self.mode.isKnown() then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(GetModeName(self.mode))
                GameTooltip:AddLine(L["MODE_NOT_LEARNED_HINT"], 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end
        end)
        button:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        modeTabButtons[#modeTabButtons + 1] = button
        previous = button
    end

    modeTabFrame:SetWidth(math.max(1, #modeTabButtons * 124))
end

UpdateModeSurface = function()
    local available = GetAvailableModes()
    local multipleModes = #available > 1
    local canChangeProtectedLayout = not InCombatLockdown()

    if mainContent and mainContent.selectAllButton then
        local disenchant = activeMode.key == "disenchant"
        mainContent.selectAllButton:SetText(L[disenchant and "MARK_DISENCHANT_PICKS" or "SELECT_ALL"])
        mainContent.selectAllButton:SetEnabled(canChangeProtectedLayout and #items > 0 and activeMode.isKnown() == true)
        mainContent.clearSelectionButton:SetEnabled(canChangeProtectedLayout and next(selected) ~= nil)
    end

    if modeTabFrame and canChangeProtectedLayout then
        if multipleModes then
            modeTabFrame:Show()
        else
            modeTabFrame:Hide()
        end
        for _, button in ipairs(modeTabButtons) do
            local mode = button.mode
            local isActive = mode == activeMode
            local isKnown = mode and mode.isKnown()
            if not isActive and isKnown then
                button:Enable()
            else
                button:Disable()
            end
            ns.SettingsTheme:PaintButton(button, isActive)
        end
    end

    if compactModeSelector and canChangeProtectedLayout then
        if multipleModes then
            compactModeSelector:Show()
        else
            compactModeSelector:Hide()
        end
        compactModeSelector:SetText(GetModeName(activeMode))
    end
    if compactNameText and compactFrame and canChangeProtectedLayout then
        compactNameText:ClearAllPoints()
        compactNameText:SetPoint("TOPLEFT", compactIcon:GetParent(), "TOPRIGHT", 8, -2)
        if multipleModes and compactModeSelector then
            compactNameText:SetPoint("RIGHT", compactModeSelector, "LEFT", -8, 0)
        else
            compactNameText:SetPoint("RIGHT", compactFrame, "RIGHT", -216, 0)
        end
    end

    if settingsFrame and settingsFrame.RefreshProtection then settingsFrame:RefreshProtection() end

    if not multipleModes and compactModeSelector then
        ns.SettingsTheme:ClosePicker(compactModeSelector)
    end
end

-- Auto-hide the FULL window when combat starts (and keep it closed).
--
-- At combat start we are already in lockdown, so a normal mainFrame:Hide() is a
-- protected operation (the window hosts the secure cast button). The only way to
-- hide it at that moment is from the secure execution environment - a state
-- driver. A stock "visibility" driver would re-SHOW the window when combat ends;
-- we deliberately do NOT want that (Oliver's design: close on pull, STAY closed,
-- reopen via the minimap button = fresh scan). So instead of the visibility
-- driver we register a custom one-way driver whose secure snippet only ever
-- hides - never shows. Out of combat it touches nothing, so manual open/close
-- keep working normally.
--
-- The compact bar can stay visible during combat. Its cast button is disarmed separately.
local mainCombatHideDriverActive = false
local function EnsureMainCombatHideDriver()
    if mainCombatHideDriverActive or not mainFrame then
        return
    end
    -- Very old clients without the secure state-driver API simply run without
    -- the auto-hide (feature-detected, same pattern as elsewhere in the addon).
    if not RegisterStateDriver then
        return
    end
    -- RegisterStateDriver / setting the secure snippet reach into the secure
    -- environment and must never run in combat. If the addon (re)loads mid-combat
    -- via /reload, this is skipped and retried from PLAYER_REGEN_ENABLED once
    -- combat ends.
    if InCombatLockdown() then
        return
    end
    -- mainFrame carries SecureHandlerStateTemplate, so this snippet runs in the
    -- secure environment whenever the "dehcombathide" state changes. On combat
    -- start it hides the window (allowed from secure code even mid-lockdown); on
    -- the way out it does nothing, so the window STAYS closed until reopened.
    mainFrame:SetAttribute("_onstate-dehcombathide", [=[
        if newstate == "combat" then
            self:Hide()
        end
    ]=])
    RegisterStateDriver(mainFrame, "dehcombathide", "[combat] combat; peace")
    mainCombatHideDriverActive = true
end

-- ---------------------------------------------------------------------------
-- Statistics window (1.8): plain text view of ns.Stats.BuildLines
-- ---------------------------------------------------------------------------
local statsFrame
local statsView = "all"

local function RefreshStatsFrame()
    if not (statsFrame and statsFrame.body and statsFrame:IsVisible()) then return end
    statsFrame.body:SetText(table.concat(ns.Stats.BuildLines(statsView), "\n"))
    statsFrame.content:SetHeight(math.max(1, statsFrame.body:GetStringHeight() or 1))
    statsFrame.scroll:RefreshRange()
end

local function OpenStatsData(maintenance)
    if not settingsFrame:IsVisible() then return end
    local transfer = Sintezza_Theme.DataTransfer
    if not transfer then Print(L["STATS_TRANSFER_REQUIRED"]); return end
    local function Clear(reset)
        return function()
            if not reset() then return nil, L["STORAGE_BLOCKED"] end
            return true
        end
    end
    local function Count(scope)
        return function()
            local casts, valued, materials = ns.Stats.Counts(scope)
            if casts == nil then return L["STORAGE_BLOCKED"] end
            return L["STATS_USAGE"]:format(casts, valued, materials, ns.Stats.MAX_MATERIALS)
        end
    end
    local spec = {
        addon = ADDON_NAME,
        title = L["STATS_TITLE"],
        columns = { "scope", "metric", "item_id", "value" },
        scopes = { { key = "all", label = L["STATS_TAB_ALL"] }, { key = "session", label = L["STATS_TAB_SESSION"] } },
        export = ns.Stats.ExportRows,
        stage = ns.Stats.StageImport,
        apply = ns.Stats.ApplyImport,
        sections = {
            { label = L["STATS_TAB_ALL"], count = Count("all"), clear = Clear(ns.Stats.ResetAll) },
            { label = L["STATS_TAB_SESSION"], count = Count("session"), clear = Clear(ns.Stats.ResetSession) },
            { label = L["STATS_LEARNING_DATA"], count = function()
                if ns.Learn.storageBlocked then return L["STORAGE_BLOCKED"] end
                local usage, limits = ns.Learn.GetStorageUsage(), ns.Learn.Limits
                return L["STATS_LEARN_USAGE"]:format(usage.groups, limits.groups, usage.materials, limits.materials)
            end, clear = Clear(ns.Learn.Reset) },
        },
        changed = function()
            RefreshStatsFrame()
            RefreshUI()
        end,
    }
    if maintenance then transfer:OpenMaintenance(settingsFrame, spec)
    else transfer:Open(settingsFrame, spec) end
end

local function CreateStatsPage(parent, W)
    statsFrame = parent
    local tabs = W:Segmented(parent, { L["STATS_TAB_ALL"], L["STATS_TAB_SESSION"] }, { "all", "session" },
        function() return statsView end, function(value)
            statsView = value
            RefreshStatsFrame()
            statsFrame.scroll:SetVerticalScroll(0)
        end)
    tabs:SetPoint("TOPLEFT")
    tabs:SetPoint("TOPRIGHT")
    local csv = W:Button(parent, L["STATS_CSV"], function() OpenStatsData(false) end, true)
    csv:SetSize(196, 24)
    csv:SetPoint("BOTTOMLEFT", 0, 0)
    local maintenance = W:Button(parent, L["STATS_MAINTENANCE"], function() OpenStatsData(true) end)
    maintenance:SetSize(155, 24)
    maintenance:SetPoint("LEFT", csv, "RIGHT", 8, 0)
    local scroll, content, scrollbar = W:ScrollFrame(parent)
    scroll:SetPoint("TOPLEFT", tabs, "BOTTOMLEFT", 0, -12)
    scroll:SetPoint("BOTTOMRIGHT", -18, 36)
    scrollbar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
    scrollbar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
    scroll:HookScript("OnSizeChanged", function(self)
        content:SetWidth(math.max(1, self:GetWidth()))
        RefreshStatsFrame()
    end)
    local body = W:Label(content, "", 12, ns.SettingsTheme.text)
    body:SetPoint("TOPLEFT", 0, 0)
    body:SetPoint("TOPRIGHT", 0, 0)
    body:SetWordWrap(true)
    statsFrame.body, statsFrame.content, statsFrame.scroll = body, content, scroll
    parent:HookScript("OnShow", RefreshStatsFrame)
    ns.Stats.onChange = RefreshStatsFrame
end

local function ToggleStatsFrame()
    ToggleSettingsFrame(true, "stats")
end

local function CreateMainFrame()
    mainFrame = CreateStyledWindow("Sintezza_Disenchant_MainFrame", 860, 580, "SecureHandlerStateTemplate", "Sintezza_Disenchant")
    mainFrame:SetPoint("CENTER")
    mainFrame:Hide()
    mainFrame.RefreshUI = RefreshUI
    mainFrame.title:SetText("Sintezza Disenchant")
    mainContent = CreateFrame("Frame", nil, mainFrame)
    mainContent:SetAllPoints(mainFrame)
    mainContent.heading = ns.InterfaceFonts:CreateText(mainContent, "OVERLAY", "GameFontNormal", db)
    mainContent.heading:SetPoint("TOPLEFT", 16, -14)
    mainContent.heading:SetText("Sintezza Disenchant")
    mainContent.heading:Hide()

    -- Child windows belong to the main window: closing it closes them too.
    -- This also fires when the combat auto-hide driver closes the window on a
    -- pull, so options/blacklist close alongside it (intended - one clean state).
    mainFrame:SetScript("OnHide", function()
        if blacklistFrame and blacklistFrame:IsShown() then
            blacklistFrame:Hide()
        end
        if settingsFrame and settingsFrame:IsShown() then
            settingsFrame:Hide()
        end
        if statsFrame and statsFrame:IsShown() then
            statsFrame:Hide()
        end
    end)

    -- Arm the combat auto-hide (deferred if we happen to load in combat).
    EnsureMainCombatHideDriver()

    CreateModeTabs()
    UpdateModeSurface()

    listPanel = CreateFrame("Frame", nil, mainContent, "BackdropTemplate")
    ns.Style.Panel(listPanel)

    local controlsFrame = CreateFrame("Frame", nil, listPanel)
    controlsFrame:SetPoint("BOTTOMLEFT", 8, 8)
    controlsFrame:SetPoint("BOTTOMRIGHT", -8, 8)
    controlsFrame:SetHeight(24)

    listScrollFrame = CreateRowsViewport(listPanel)
    listScrollFrame:SetPoint("TOPLEFT", 8, -8)
    listScrollFrame:SetPoint("BOTTOMRIGHT", controlsFrame, "TOPRIGHT", -22, 8)

    local empty = listPanel:CreateFontString(nil, "OVERLAY")
    ns.SettingsTheme:Font(empty, 16, "", ns.SettingsTheme.muted, "display")
    empty:SetPoint("TOPLEFT", listScrollFrame, "TOPLEFT", 12, -44)
    empty:SetPoint("TOPRIGHT", listScrollFrame, "TOPRIGHT", -12, -44)
    empty:SetJustifyH("CENTER")
    empty:SetWordWrap(true)
    empty:Hide()
    listScrollFrame.empty = empty

    local refreshButton = ns.Style.Button(controlsFrame)
    refreshButton:SetSize(86, 22)
    refreshButton:SetPoint("RIGHT", controlsFrame, "RIGHT", 0, 0)
    refreshButton:SetText(L["REFRESH"])
    refreshButton:SetScript("OnClick", RefreshList)

    local clearButton = ns.Style.Button(controlsFrame)
    clearButton:SetSize(112, 22)
    clearButton:SetPoint("RIGHT", refreshButton, "LEFT", -8, 0)
    clearButton:SetText(L["CLEAR_SELECTION"])
    clearButton:SetScript("OnClick", function()
        if InCombatLockdown() then return end
        bulkMessage = nil
        wipe(selected)
        BuildQueue()
        RefreshUI()
    end)
    mainContent.clearSelectionButton = clearButton

    local selectAllButton = ns.Style.Button(controlsFrame)
    selectAllButton:SetSize(136, 22)
    selectAllButton:SetPoint("RIGHT", clearButton, "LEFT", -8, 0)
    mainContent.selectAllButton = selectAllButton
    selectAllButton:SetScript("OnClick", function(button)
        if InCombatLockdown() or not activeMode.isKnown() then return end
        ScanBags()
        if activeMode.key == "disenchant" then
            local candidates = {}
            for _, item in ipairs(items) do
                if not IsAutoQueueProtected(item) then candidates[#candidates + 1] = item end
            end
            local advice = #candidates > 0 and ns.Mastercraft and ns.Mastercraft.ReadAdvice(candidates, button)
            local fallback, count = false, 0
            wipe(selected)
            for _, item in ipairs(candidates) do
                local pick, usedFallback = ns.Prediction.IsDisenchantPick(item, advice and advice[item.key])
                fallback = fallback or usedFallback
                if pick then
                    selected[item.key] = true
                    count = count + 1
                end
            end
            bulkMessage = string.format(L["PICKS_COUNT"], count)
            if fallback then bulkMessage = bulkMessage .. " · " .. L["PICKS_FALLBACK"] end
        else
            for _, item in ipairs(items) do
                if not IsAutoQueueProtected(item) then selected[item.key] = true end
            end
        end
        BuildQueue()
        RefreshUI()
    end)

    statusText = ns.InterfaceFonts:CreateText(controlsFrame, "OVERLAY", "GameFontNormal", db)
    statusText:SetPoint("LEFT", controlsFrame, "LEFT", 0, 0)
    statusText:SetPoint("RIGHT", selectAllButton, "LEFT", -8, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(false)
    function mainContent:LayoutListFooter()
        local width = controlsFrame:GetWidth()
        local narrow = width < 560
        controlsFrame:SetHeight(narrow and 43 or 24)
        local edge = narrow and "BOTTOMRIGHT" or "RIGHT"
        refreshButton:ClearAllPoints()
        refreshButton:SetPoint(edge, controlsFrame, edge, 0, 0)
        local buttonSpace = math.max(3, width - 16)
        refreshButton:SetWidth(math.max(1, math.min(86, math.floor(buttonSpace * .26))))
        clearButton:SetWidth(math.max(1, math.min(112, math.floor(buttonSpace * .33))))
        selectAllButton:SetWidth(math.max(1, math.min(136, math.floor(buttonSpace * .41))))
        statusText:ClearAllPoints()
        if narrow then
            statusText:SetPoint("TOPLEFT", controlsFrame, "TOPLEFT")
            statusText:SetPoint("TOPRIGHT", controlsFrame, "TOPRIGHT")
        else
            statusText:SetPoint("LEFT", controlsFrame, "LEFT")
            statusText:SetPoint("RIGHT", selectAllButton, "LEFT", -8, 0)
        end
    end
    controlsFrame:SetScript("OnSizeChanged", function(_, width)
        if controlsFrame.footerWidth == width then return end
        controlsFrame.footerWidth = width
        mainContent:LayoutListFooter()
    end)

    queuePanel = CreateFrame("Frame", nil, mainContent, "BackdropTemplate")
    ns.Style.Panel(queuePanel)
    queuePanel:Hide()

    local queueTitle = ns.InterfaceFonts:CreateText(queuePanel, "OVERLAY", "GameFontHighlight", db)
    queueTitle:SetPoint("TOP", 0, -10)
    queueTitle:SetText(L["QUEUE_TITLE"])

    blacklistOpenButton = ns.Style.Button(mainContent)
    blacklistOpenButton:SetSize(24, 22)
    -- No custom strata: the button inherits the main window's layer and only
    -- rises above the title bar within it - so it correctly disappears when
    -- the window sits behind other windows.
    blacklistOpenButton:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
    for index = 1, 3 do
        local line = blacklistOpenButton:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(unpack(ns.SettingsTheme.accent))
        line:SetSize(9, 1)
        line:SetPoint("TOPLEFT", 4, -5 - (index - 1) * 5)
    end
    for index = 1, 2 do
        local stroke = blacklistOpenButton:CreateTexture(nil, "ARTWORK")
        stroke:SetColorTexture(unpack(ns.SettingsTheme.accent))
        stroke:SetSize(8, 1.5)
        stroke:SetPoint("BOTTOMRIGHT", -3, 5)
        stroke:SetRotation(index == 1 and math.pi / 4 or -math.pi / 4)
    end
    blacklistOpenButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["BLACKLIST_TITLE"])
        GameTooltip:Show()
    end)
    blacklistOpenButton:HookScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    blacklistOpenButton:HookScript("OnHide", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    blacklistOpenButton:SetScript("OnClick", function()
        ToggleBlacklistFrame()
    end)

    local compactModeButton = ns.Style.Button(mainContent)
    mainContent.compactModeButton = compactModeButton
    compactModeButton:SetSize(80, 24)
    compactModeButton:Hide()
    compactModeButton:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
    compactModeButton:SetText(L["COMPACT_BUTTON"])
    compactModeButton:SetScript("OnClick", function()
        if mainFrame.professionContent and not InCombatLockdown() and ns.ProfessionTab and ns.ProfessionTab.Toggle then
            ns.ProfessionTab.Toggle()
        end
        SetCompactMode(true)
    end)

    local settingsButton = ns.Style.Button(mainContent)
    mainContent.settingsButton = settingsButton
    settingsButton:SetSize(80, 22)
    settingsButton:SetPoint("RIGHT", mainFrame.CloseButton, "LEFT", -8, 0)
    settingsButton:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
    settingsButton:SetText(L["SETTINGS_BUTTON"])
    settingsButton:SetScript("OnClick", function()
        ToggleSettingsFrame()
    end)

    local statsButton = ns.Style.Button(mainContent)
    mainContent.statsButton = statsButton
    local titlePoint = { mainFrame.title:GetPoint(1) }
    function mainContent:AnchorMainTitle()
        mainFrame.title:ClearAllPoints()
        mainFrame.title:SetPoint(unpack(titlePoint))
        if not mainFrame.TitleBar.version then
            mainFrame.title:SetPoint("RIGHT", blacklistOpenButton, "LEFT", -12, 0)
        end
    end
    statsButton:SetSize(80, 22)
    statsButton:SetPoint("RIGHT", settingsButton, "LEFT", -8, 0)
    blacklistOpenButton:SetPoint("RIGHT", statsButton, "LEFT", -8, 0)
    statsButton:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
    mainContent:AnchorMainTitle()
    statsButton:SetText(L["STATS_BUTTON"])
    statsButton:SetScript("OnClick", function()
        ToggleStatsFrame()
    end)

    queueInfoText = ns.InterfaceFonts:CreateText(queuePanel, "OVERLAY", "GameFontNormalSmall", db)
    queueInfoText:SetPoint("TOPLEFT", 10, -32)
    queueInfoText:SetPoint("TOPRIGHT", -10, -32)
    queueInfoText:SetJustifyH("LEFT")
    queueInfoText:SetText(L["QUEUE_EMPTY"])

    local divider = queuePanel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 0.82, 0, 0.12)
    divider:SetPoint("TOPLEFT", 10, -54)
    divider:SetPoint("TOPRIGHT", -10, -54)
    divider:SetHeight(1)

    queueScrollFrame = CreateRowsViewport(queuePanel)
    queueScrollFrame:SetPoint("TOPLEFT", 8, -60)
    queueScrollFrame:SetPoint("BOTTOMRIGHT", -30, 46)

    queueButton = ns.Style.Button(queuePanel, QUEUE_BUTTON_NAME, true)
    queueButton:SetSize(122, 24)
    queueButton:SetPoint("BOTTOMRIGHT", queuePanel, "BOTTOMRIGHT", -16, 12)
    UpdateQueueButtonClickRegistration()
    queueButton:EnableMouse(true)
    queueButtonText = queueButton:GetFontString()
    if queueButtonText then
        queueButtonText:SetText(L[activeMode.buttonTextKey] or L["DISENCHANT"])
    end
    -- No down-edge guard needed: only ONE click edge is registered (matched to
    -- the cast-on-key-down CVar), so every PreClick call IS the action edge.
    queueButton:SetScript("PreClick", function(self)
        if InCombatLockdown() then return end
        -- Hotkey safety (1.7.0): a key binding can "click" this button even
        -- while it is NOT on screen (main window closed, queue panel hidden).
        -- A mouse click can never come from an invisible button, so this only
        -- affects hotkeys: with nothing visible there is nothing the user can
        -- see being disenchanted, and disenchanting is irreversible - so swallow
        -- the press (the attributes are re-armed on the next refresh).
        if not self:IsVisible() then
            ClearQueueButtonAttributes()
            return
        end

        local now = GetTime()
        -- Debounce: after a cast the bag needs a moment to update and the
        -- button to re-point to the next item; ignore clicks until then.
        if now < (nextAllowedQueueClickAt or 0) then
            ClearQueueButtonAttributes()
            self:Disable()
            UpdateQueueButtonVisual(queueButtonText and queueButtonText:GetText() or L[activeMode.buttonTextKey] or L["DISENCHANT"])
            if C_Timer and C_Timer.After then
                C_Timer.After(0.2, function()
                    -- Always re-enable - UpdateQueueButton guards itself.
                    -- (Previously this only ran with the main window open, so
                    -- spamming in compact mode left the button disabled forever.)
                    UpdateQueueButton()
                end)
            end
            return
        end

        if not queue[1] then
            ClearQueueButtonAttributes()
            ClearPendingDisenchant()
            return
        end

        -- SAFETY NET: never cast at a stale slot. The armed target-bag/slot
        -- were captured at the last refresh; if the bag shifted since (loot in
        -- combat, item dragged, /sde check rebuilt the queue), the slot may now
        -- hold a DIFFERENT item - and disenchanting is irreversible. Verify the
        -- armed slot still holds queue[1]; if not, swallow this click and re-arm.
        local item = queue[1]
        local armedBag = self:GetAttribute("target-bag")
        local armedSlot = self:GetAttribute("target-slot")
        if not item or IsBlacklistedItem(item.link) or item.bag ~= armedBag or item.slot ~= armedSlot
            or GetBagItemLinkSafe(item.bag, item.slot) ~= item.link
            or ComputeItemKey(item.bag, item.slot, item.link) ~= item.key then
            ClearQueueButtonAttributes()
            self:Disable()
            UpdateQueueButtonVisual(L[activeMode.buttonTextKey] or L["DISENCHANT"])
            if C_Timer and C_Timer.After then
                C_Timer.After(0.2, function()
                    RefreshList()
                end)
            end
            return
        end

        if activeMode.key == "disenchant" and TooltipSaysCantDisenchant(item) then
            ClearQueueButtonAttributes()
            self:Disable()
            UpdateQueueButtonVisual(L[activeMode.buttonTextKey] or L["DISENCHANT"])
            ClearPendingDisenchant()
            -- Rearming inside PreClick would let this click cast at the next item.
            C_Timer.After(0, function() MarkCannotDisenchant(item) end)
            return
        end

        nextAllowedQueueClickAt = now + 0.35
        -- Learning (1.8): snapshot the item NOW (the cast destroys it). Only
        -- here, where the cast really fires - not on the blacklist paths -
        -- and in pcall: statistics must never be able to block a cast.
        if ns.Learn and activeMode and activeMode.key == "disenchant" then
            pcall(ns.Learn.Begin, queue[1], queue[1].manualOnly)
        end
        if activeMode.key == "disenchant" then
            SetPendingDisenchant(item)
        end
    end)

    blacklistFrame = CreateStyledWindow("Sintezza_Disenchant_BlacklistFrame", 500, 420)
    blacklistFrame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    blacklistFrame:Hide()
    blacklistFrame:SetScript("OnShow", function(self)
        RaiseAddonWindows(self)
    end)
    blacklistFrame.title:SetText(L["BLACKLIST_TITLE"])

    blacklistScrollFrame = CreateFrame("ScrollFrame", nil, blacklistFrame, "BackdropTemplate")
    ns.SettingsTheme:AttachScrollBar(blacklistScrollFrame, blacklistFrame)
    blacklistScrollFrame:SetPoint("TOPLEFT", 12, -54)
    blacklistScrollFrame:SetPoint("BOTTOMRIGHT", -30, 44)

    blacklistScrollChild = CreateFrame("Frame", nil, blacklistScrollFrame)
    blacklistScrollChild:SetSize(1, 1)
    blacklistScrollFrame:SetScrollChild(blacklistScrollChild)

    blacklistEmptyText = ns.InterfaceFonts:CreateText(blacklistFrame, "OVERLAY", "GameFontDisable", db)
    blacklistEmptyText:SetPoint("TOPLEFT", blacklistScrollFrame, "TOPLEFT", 4, -4)
    blacklistEmptyText:SetText(L["BLACKLIST_EMPTY"])

    local clearBlacklistButton = ns.Style.Button(blacklistFrame)
    clearBlacklistButton:SetSize(110, 22)
    clearBlacklistButton:SetPoint("BOTTOMRIGHT", blacklistFrame, "BOTTOMRIGHT", -12, 12)
    clearBlacklistButton:SetText(L["CLEAR_ALL"])
    clearBlacklistButton:SetScript("OnClick", function()
        wipe(GetModeBlacklist())
        RefreshBlacklistUI()
        RefreshList()
    end)
end

local function CreateMinimapButton()
    minimapButton = Sintezza_Theme:CreateMinimapButton(ADDON_NAME, Sintezza_Theme.icons.Sintezza_Disenchant, db.minimap,
        function()
            local tab = db.minimapDestination == "profession" and ns.ProfessionTab
            if tab and tab.Toggle and tab.Toggle() then return end
            if db.minimapDestination == "stats" then ToggleStatsFrame() else ToggleMainFrame() end
        end,
        function(tooltip)
            tooltip:AddLine("Sintezza Disenchant")
            local integrated = db.minimapDestination == "profession" and ns.ProfessionTab and ns.ProfessionTab.Open
            local left = integrated and "MM_LEFT_PROFESSION" or (db.minimapDestination == "stats" and "MM_LEFT_STATS" or "MM_LEFT")
            tooltip:AddLine(L[left], 1, 1, 1)
            tooltip:AddLine(L["MM_DRAG"], 1, 1, 1)
        end)
end

local function CreateCompactFrame()
    compactFrame = CreateFrame("Frame", "Sintezza_Disenchant_CompactFrame", UIParent, "BackdropTemplate")
    compactFrame:SetSize(400, 58)
    if db.compactPoint then
        compactFrame:SetPoint(db.compactPoint.point or "CENTER", UIParent, db.compactPoint.relPoint or "CENTER", db.compactPoint.x or 0, db.compactPoint.y or 0)
    else
        compactFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -220)
    end
    ns.Style.Window(compactFrame)
    compactFrame:SetMovable(true)
    compactFrame:EnableMouse(true)
    compactFrame:RegisterForDrag("LeftButton")
    compactFrame:SetClampedToScreen(true)
    compactFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    compactFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        db.compactPoint = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    compactFrame:Hide()

    local closeButton = Sintezza_Theme:CreateWidgets(ns.SettingsTheme):CloseButton(compactFrame)
    closeButton:SetPoint("TOPRIGHT", 2, 2)
    closeButton:SetScale(0.7)
    closeButton:SetScript("OnClick", function()
        -- Same combat rule as the styled windows: the bar hosts the secure
        -- button in compact mode, so hiding it is protected in combat.
        if InCombatLockdown() and compactFrame:IsProtected() then
            Print(L["NOT_IN_COMBAT"])
            return
        end
        compactFrame:Hide()
    end)

    local iconBorder = CreateIconBorder(compactFrame, 34)
    iconBorder:SetPoint("TOPLEFT", 12, -12)

    compactIcon = iconBorder.itemIcon

    iconBorder:EnableMouse(true)
    iconBorder:SetScript("OnEnter", function(self)
        local item = compactFrame and compactFrame.currentItem
        if not item then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetBagItem(item.bag, item.slot)
        if ns.Prediction and activeMode and activeMode.key == "disenchant" and db and db.showExpected ~= false then
            ns.Prediction.AppendToTooltip(GameTooltip, item)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L[activeMode.blacklistHintKey or "COMPACT_BLACKLIST_HINT"] or L["COMPACT_BLACKLIST_HINT"], 0.6, 0.8, 1)
        GameTooltip:Show()
    end)
    iconBorder:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    iconBorder:SetScript("OnMouseUp", function(_, mouseButton)
        if mouseButton ~= "RightButton" then
            return
        end
        local item = compactFrame and compactFrame.currentItem
        if not item then
            return
        end
        GameTooltip:Hide()
        AddItemToBlacklist(item)
    end)

    compactFullButton = ns.Style.Button(compactFrame)
    compactFullButton:SetSize(48, 24)
    compactFullButton:SetPoint("TOPRIGHT", compactFrame, "TOPRIGHT", -24, -16)
    compactFullButton:SetText(L["FULL_BUTTON"])
    compactFullButton:SetScript("OnClick", function()
        SetCompactMode(false)
    end)

    compactModeSelector = ns.Style.Button(compactFrame)
    ns.SettingsTheme:DropdownArrow(compactModeSelector, compactModeSelector:GetFontString())
    compactModeSelector:SetSize(90, 20)
    compactModeSelector:SetPoint("TOPRIGHT", compactFrame, "TOPRIGHT", -214, -18)
    compactModeSelector:SetScript("OnClick", function(owner)
        if InCombatLockdown() then
            Print(L["MODE_CHANGE_IN_COMBAT"] or L["NOT_IN_COMBAT"])
            return
        end
        local entries = {}
        for index, mode in ipairs(GetAvailableModes()) do
            entries[index] = { value = mode, label = GetModeName(mode), disabled = not mode.isKnown() }
        end
        ns.SettingsTheme:OpenPicker(owner, entries, activeMode, SelectModeFromSurface)
    end)
    compactModeSelector:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(L["MODE_SWITCH_HINT"], 0.7, 0.8, 1, true)
        GameTooltip:Show()
    end)
    compactModeSelector:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    compactNameText = ns.InterfaceFonts:CreateText(compactFrame, "OVERLAY", "GameFontNormal", db)
    compactNameText:SetPoint("TOPLEFT", iconBorder, "TOPRIGHT", 8, -2)
    compactNameText:SetPoint("RIGHT", compactFrame, "RIGHT", -216, 0)
    compactNameText:SetJustifyH("LEFT")
    compactNameText:SetWordWrap(false)

    compactQueueText = ns.InterfaceFonts:CreateText(compactFrame, "OVERLAY", "GameFontNormalSmall", db)
    compactQueueText:SetPoint("BOTTOMLEFT", compactFrame, "BOTTOMLEFT", 14, 8)
    compactQueueText:SetPoint("RIGHT", compactFrame, "RIGHT", -14, 0)
    compactQueueText:SetJustifyH("LEFT")
    compactQueueText:SetWordWrap(false)
    compactQueueText:SetTextColor(0.75, 0.75, 0.75)

    compactPreviewText = ns.InterfaceFonts:CreateText(compactFrame, "OVERLAY", "GameFontNormalSmall", db)
    compactPreviewText:SetPoint("BOTTOMLEFT", iconBorder, "BOTTOMRIGHT", 8, 2)
    compactPreviewText:SetPoint("RIGHT", compactNameText, "RIGHT", 0, 0)
    compactPreviewText:SetJustifyH("LEFT")
    compactPreviewText:SetWordWrap(false)
    compactPreviewText:SetTextColor(0.75, 0.8, 0.9)

    UpdateModeSurface()
end

-- ---------------------------------------------------------------------------
-- Hotkey (1.7.0)
-- The real binding lives in the client's own binding system (CLICK binding on
-- the queue button, see Bindings.xml): it is saved per the user's binding set,
-- listed under Options > Key Bindings > Sintezza Disenchant and conflict-checked by the
-- client. The settings window only offers a shortcut to set/clear it there.
-- ---------------------------------------------------------------------------
local hotkeyButton
local hotkeyClearButton
local hotkeyCapturing = false

local MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, LMETA = true, RMETA = true, UNKNOWN = true,
}

local function CanEditBindings()
    return type(SetBinding) == "function" and type(GetBindingKey) == "function"
        and type(GetBindingAction) == "function"
        and (type(SaveBindings) == "function" or type(AttemptToSaveBindings) == "function")
        and type(GetCurrentBindingSet) == "function"
end

local function ChangeHotkey(binding)
    if not CanEditBindings() then return false end

    local save = type(SaveBindings) == "function" and SaveBindings or AttemptToSaveBindings
    local bindingSet = GetCurrentBindingSet()
    if bindingSet ~= 1 and bindingSet ~= 2 then return false end

    local changes = {}
    for _, key in ipairs({ GetBindingKey(QUEUE_BINDING) }) do
        if key ~= binding then
            changes[#changes + 1] = { key = key, previous = QUEUE_BINDING }
        end
    end
    local previous
    if binding then
        previous = GetBindingAction(binding)
        if previous ~= QUEUE_BINDING then
            changes[#changes + 1] = { key = binding, previous = previous, action = QUEUE_BINDING }
        end
    end
    if #changes == 0 then return true end

    local function Rollback(last)
        local function Restore(i)
            local change = changes[i]
            if (GetBindingAction(change.key) or "") ~= (change.previous or "") then
                pcall(SetBinding, change.key, change.previous ~= "" and change.previous or nil)
            end
        end
        -- Restore the new key's owner before putting back the queue's old keys.
        if changes[last].action then
            Restore(last)
            last = last - 1
        end
        for i = 1, last do Restore(i) end
    end

    for i, change in ipairs(changes) do
        local ok, result = pcall(SetBinding, change.key, change.action)
        if not ok or not result or (GetBindingAction(change.key) or "") ~= (change.action or "") then
            Rollback(i)
            return false
        end
    end
    local ok, result = pcall(save, bindingSet)
    if not ok or result == false then
        Rollback(#changes)
        return false
    end
    return true, previous
end

local function FormatBindingKey(key)
    if GetBindingText then
        return GetBindingText(key, "KEY_") or key
    end
    return key
end

local function RefreshHotkeyDisplay()
    if not hotkeyButton or hotkeyCapturing then
        return
    end
    local key1, key2 = nil, nil
    if GetBindingKey then
        key1, key2 = GetBindingKey(QUEUE_BINDING)
    end
    if key1 then
        local text = FormatBindingKey(key1)
        if key2 then
            text = text .. ", " .. FormatBindingKey(key2)
        end
        hotkeyButton.text:SetText(text)
        hotkeyClearButton:SetEnabled(CanEditBindings())
    else
        hotkeyButton.text:SetText(L["HOTKEY_NOT_BOUND"])
        hotkeyClearButton:Disable()
    end
end

local function StopHotkeyCapture()
    hotkeyCapturing = false
    if hotkeyButton then
        hotkeyButton:EnableKeyboard(false)
    end
    RefreshHotkeyDisplay()
end

local function ApplyHotkey(binding)
    if InCombatLockdown() then
        Print(L["HOTKEY_IN_COMBAT"])
        return
    end

    local changed, existing = ChangeHotkey(binding)
    if not changed then
        Print(L["HOTKEY_CHANGE_FAILED"])
        return
    end
    if existing and existing ~= "" and existing ~= QUEUE_BINDING then
        local actionName = (GetBindingName and GetBindingName(existing)) or existing
        Print(string.format(L["HOTKEY_REPLACED"], FormatBindingKey(binding), tostring(actionName)))
    end
    Print(string.format(L["HOTKEY_SET"], FormatBindingKey(binding)))
end

local function ClearHotkey()
    if InCombatLockdown() then
        Print(L["HOTKEY_IN_COMBAT"])
        return
    end
    if not ChangeHotkey() then
        Print(L["HOTKEY_CHANGE_FAILED"])
    end
    RefreshHotkeyDisplay()
end

local function StartHotkeyCapture()
    if InCombatLockdown() then
        Print(L["HOTKEY_IN_COMBAT"])
        return
    end
    hotkeyCapturing = true
    hotkeyButton.text:SetText(L["HOTKEY_PRESS"])
    hotkeyButton:EnableKeyboard(true)
end

local function CreateSettingsFrame()
    settingsFrame = CreateStyledWindow("Sintezza_Disenchant_SettingsFrame", 590, 544, nil, ADDON_NAME)
    settingsFrame:SetPoint("CENTER", UIParent, "CENTER", -300, 0)
    settingsFrame:Hide()
    settingsFrame.title:SetText(L["SETTINGS_TITLE"])
    local T = ns.SettingsTheme
    local W = Sintezza_Theme:CreateWidgets(T)
    local pages, selectedPage = {}, "protection"
    local tabs
    local function SelectPage(page)
        if not pages[page] then return end
        selectedPage = page
        for key, panel in pairs(pages) do panel:SetShown(key == page) end
        tabs:Refresh()
    end
    tabs = W:Segmented(settingsFrame,
        { L["QUEUE_PROTECTION"], L["STATS_BUTTON"], L["WINDOW_MINIMAP"] },
        { "protection", "stats", "window" }, function() return selectedPage end, SelectPage)
    tabs:SetPoint("TOPLEFT", 14, -51)
    tabs:SetPoint("TOPRIGHT", -14, -51)
    settingsFrame.SelectPage = SelectPage

    local function Page(key)
        local panel = CreateFrame("Frame", nil, settingsFrame)
        panel:SetPoint("TOPLEFT", tabs, "BOTTOMLEFT", 2, -12)
        panel:SetPoint("BOTTOMRIGHT", settingsFrame, "BOTTOMRIGHT", -18, 16)
        pages[key] = panel
        panel:Hide()
        return panel
    end
    local function ScrollPage(key)
        local panel = Page(key)
        local scroll, body, bar = W:ScrollFrame(panel)
        scroll:SetPoint("TOPLEFT")
        scroll:SetPoint("BOTTOMRIGHT", -15, 0)
        bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
        bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
        scroll:HookScript("OnSizeChanged", function(self) body:SetWidth(math.max(1, self:GetWidth())) end)
        local rows = {}
        local function Add(row, show)
            rows[#rows + 1] = { row = row, show = show }
            return row
        end
        local function Layout()
            local y = 0
            for _, entry in ipairs(rows) do
                local row = entry.row
                local shown = not entry.show or entry.show()
                if shown then
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
                    row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
                    y = y + row:GetHeight() + 4
                end
                row:SetShown(shown == true)
            end
            body:SetHeight(math.max(1, y))
            scroll:RefreshRange()
        end
        return panel, body, Add, Layout
    end
    local function Text(parent, label, height, color)
        local row = W:SettingRow(parent, label, height)
        row.label:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.label:SetWordWrap(true)
        row.label:SetTextColor(unpack(color))
        return row
    end

    local protection, body, Add, Layout = ScrollPage("protection")
    local refreshers = {}
    local function Register(row, show)
        if row.Refresh then refreshers[#refreshers + 1] = row end
        return Add(row, show)
    end
    local function IsProtectionMode() return activeMode and activeMode.usesItemProtection == true end
    local function LevelEnabled() return IsProtectionMode() and db.ilvlCapEnabled == true end
    local function PriceEnabled() return IsProtectionMode() and db.priceWarnEnabled == true end
    local function UpdateQueueSettings()
        settingsFrame:RefreshProtection()
        RefreshList()
    end
    local function Toggle(label, get, set, show)
        return Register(W:Toggle(body, label, get, set), show)
    end
    local function ToggleField(label, key, show)
        return Toggle(label, function() return db[key] == true end, function(value)
            db[key] = value
            UpdateQueueSettings()
        end, show)
    end
    local function GuardChoice(label, onLabel, key, help)
        local row = W:ChoiceRow(body, label, { off = L["GUARD_OFF"], active = onLabel },
            function() return db[key] and "active" or "off" end, function(value)
                db[key] = value == "active"
                UpdateQueueSettings()
            end, { off = 1, active = 2 })
        if W.Help then W:Help(row, help) end
        Register(row, IsProtectionMode)
    end
    local function NumberRow(label, key, minimum, maximum, fraction, show)
        local row = W:SettingRow(body, label)
        row.label:SetPoint("RIGHT", row, "RIGHT", -90, 0)
        local unit = W:Label(row, "", 11, T.muted)
        unit:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        if fraction then
            local coin = C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString and C_CurrencyInfo.GetCoinTextureString(10000, 12)
            unit:SetText(type(coin) == "string" and (coin:match("(|A:.-|a)") or coin:match("(|T.-|t)"))
                or "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12|t")
            unit:SetWidth(16)
        else
            unit:SetText("ilvl")
            unit:SetWidth(26)
        end
        local edit = W:EditBox(row, "", function() end)
        edit:SetSize(50, 24)
        edit:SetPoint("RIGHT", unit, "LEFT", -3, 0)
        edit:SetTextInsets(5, 5, 0, 0)
        edit:SetJustifyH("RIGHT")
        edit:SetMaxLetters(14)
        local function CurrentText() return db[key] and tostring(db[key]) or "" end
        function row:Refresh()
            if not edit:HasFocus() then edit:SetText(CurrentText()) end
        end
        local function Commit()
            local value = strtrim(edit:GetText() or ""):gsub(",", ".")
            if value == CurrentText() then W:SetInputError(row); return true end
            if value == "" then
                db[key] = nil
            else
                local number = value:match(fraction and "^%d+%.?%d?%d?$" or "^%d+$") and tonumber(value)
                if not number or number < minimum or number > maximum then
                    W:SetInputError(row, L[fraction and "GUARD_INVALID_PRICE" or "GUARD_INVALID_LEVEL"])
                    return false
                end
                db[key] = number
            end
            W:SetInputError(row)
            UpdateQueueSettings()
            return true
        end
        local skipping
        edit:SetScript("OnEnterPressed", function(self)
            if not Commit() then return end
            skipping = true
            self:ClearFocus()
        end)
        edit:HookScript("OnEditFocusLost", function()
            if not skipping then Commit() end
            skipping = nil
            row:Refresh()
        end)
        edit:SetScript("OnEscapePressed", function(self)
            skipping = true
            W:SetInputError(row)
            self:ClearFocus()
        end)
        return Register(row, show)
    end

    do
        local row = W:SettingRow(body, L["QUEUE_QUALITY"])
        local button
        local qualities = { UNCOMMON_QUALITY, RARE_QUALITY, EPIC_QUALITY }
        local fallbackColors = { [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee" }
        local function ColoredName(quality)
            local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
            return ((color and color.hex) or fallbackColors[quality]) .. L["QUALITY_" .. quality] .. "|r"
        end
        local function OpenQualityPicker()
            local entries = {}
            for _, quality in ipairs(qualities) do
                local icon = db.qualityFilter[quality] ~= false and "UI-CheckBox-Check" or "UI-CheckBox-Up"
                entries[#entries + 1] = { value = quality,
                    label = "|TInterface\\Buttons\\" .. icon .. ":14:14|t " .. ColoredName(quality) }
            end
            T:OpenPicker(button, entries, nil, function(quality)
                db.qualityFilter[quality] = db.qualityFilter[quality] == false
                UpdateQueueSettings()
                if button:IsVisible() then OpenQualityPicker() end
            end)
        end
        button = W:Button(row, "", OpenQualityPicker)
        T:DropdownArrow(button, button.text)
        button:SetSize(230, 22)
        button:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT")
        row.label:SetPoint("RIGHT", button, "LEFT", -8, 0)
        function row:Refresh()
            local selected = {}
            for _, quality in ipairs(qualities) do
                if db.qualityFilter[quality] ~= false then selected[#selected + 1] = ColoredName(quality) end
            end
            button.text:SetText(#selected > 0 and table.concat(selected, ", ") or L["QUALITY_NONE"])
        end
        Register(row)
    end
    Add(Text(body, L["MODE_NO_PROTECTION_SETTINGS"], 42, T.muted), function() return not IsProtectionMode() end)
    ToggleField(L["GUARD_SET"], "protectSets", IsProtectionMode)
    GuardChoice(L["ILVL_PROTECT"], L["GUARD_LEVEL_FROM"], "ilvlCapEnabled", L["GUARD_LEVEL_HELP"])
    NumberRow(L["GUARD_LEVEL_VALUE"], "ilvlCap", 1, 2000, false, LevelEnabled)
    Add(W:ActionRow(body, L["GUARD_EQUIPPED_LOWEST"], L["ILVL_SUGGEST"], function()
        local lowest = GetLowestEquippedItemLevel()
        if lowest then db.ilvlCap = lowest; UpdateQueueSettings() end
    end), LevelEnabled)
    Add(Text(body, L["ILVL_CAP_EMPTY"], 32, T.warning), function()
        local level = tonumber(db.ilvlCap)
        return LevelEnabled() and (not level or level < 0 or not (level < math.huge))
    end)
    GuardChoice(L["PRICE_PROTECT"], L["GUARD_PRICE_FROM"], "priceWarnEnabled", L["GUARD_PRICE_HELP"])
    NumberRow(L["GUARD_PRICE_VALUE"], "priceThresholdGold", .01, 100000, true, PriceEnabled)
    Register(W:ChoiceRow(body, L["GUARD_UNKNOWN_PRICE"], { allow = L["GUARD_ALLOW"], skip = L["GUARD_SKIP"] },
        function() return db.skipUnknownPrice and "skip" or "allow" end, function(value)
            db.skipUnknownPrice = value == "skip"
            UpdateQueueSettings()
        end, { allow = 1, skip = 2 }), PriceEnabled)
    local priceStatus = Add(Text(body, "", 34, T.muted), PriceEnabled)
    Add(Text(body, L["GUARD_MANUAL"], 30, T.muted), IsProtectionMode)

    Toggle(L["PREVIEW_HELPER"], function() return db.showExpected ~= false end, function(value)
        db.showExpected = value
        RefreshUI()
    end)
    Toggle(L["PREVIEW_EXTERNAL"], function() return db.externalItemTooltips == true end, function(value)
        db.externalItemTooltips = value
    end)

    local function PriceStatus()
        if PriceProtectionThreshold() == nil then return L["PRICE_THRESHOLD_EMPTY"], T.warning end
        if not ns.Prices.HasAnySource() then return L["GUARD_NO_PROVIDER"], T.warning end
        if #items == 0 then return L["GUARD_NO_ITEMS"], T.muted end
        local missing = 0
        for _, item in ipairs(items) do if item.priceCopper == nil then missing = missing + 1 end end
        if missing == #items then return L["GUARD_NO_QUOTES"], T.warning end
        return L["GUARD_QUOTES"]:format(#items - missing, #items), missing > 0 and T.warning or T.muted
    end
    local refreshing
    function settingsFrame:RefreshProtection()
        if refreshing or not protection:IsVisible() then return end
        refreshing = true
        for _, row in ipairs(refreshers) do row:Refresh() end
        if PriceEnabled() then
            local message, color = PriceStatus()
            priceStatus.label:SetText(message)
            priceStatus.label:SetTextColor(unpack(color))
        end
        Layout()
        refreshing = nil
    end
    protection:HookScript("OnShow", function() settingsFrame:RefreshProtection() end)

    CreateStatsPage(Page("stats"), W)
    local window, windowBody, AddWindow, LayoutWindow = ScrollPage("window")
    local windowOptions = AddWindow(Sintezza_Theme:CreateWindowOptions(windowBody, T, {
        windows = { { prefs = windowAppearance } },
        getMinimap = function() return not db.minimap.hide end,
        setMinimap = function(value)
            db.minimap.hide = not value
            if minimapButton then minimapButton:Refresh(db.minimap) end
        end,
    }))
    local destination = AddWindow(W:ChoiceRow(windowBody, L["MM_DESTINATION"], function()
        local choices = { window = L["MM_QUEUE"], stats = L["STATS_BUTTON"] }
        if (ns.ProfessionTab and ns.ProfessionTab.Open) or db.minimapDestination == "profession" then
            choices.profession = L["MM_PROFESSION"]
        end
        return choices
    end, function() return db.minimapDestination end, function(value) db.minimapDestination = value end,
        { profession = 1, window = 2, stats = 3 }))
    AddWindow(Text(windowBody, L["HOTKEY_HEADER"], 26, T.brass))
    local keys = AddWindow(CreateFrame("Frame", nil, windowBody))
    keys:SetHeight(28)
    hotkeyButton = W:Button(keys, "")
    hotkeyButton:SetSize(174, 24)
    hotkeyButton:SetPoint("LEFT")
    hotkeyClearButton = W:Button(keys, L["HOTKEY_CLEAR"])
    hotkeyClearButton:SetSize(156, 24)
    hotkeyClearButton:SetPoint("LEFT", hotkeyButton, "RIGHT", 8, 0)
    local hotkeyHint = AddWindow(Text(windowBody, "", 58, T.muted))
    if CanEditBindings() then
        hotkeyHint.label:SetText(L["HOTKEY_HINT"])
        hotkeyButton:RegisterForClicks("LeftButtonUp")
        hotkeyButton:SetScript("OnClick", function()
            if hotkeyCapturing then
                StopHotkeyCapture()
            else
                StartHotkeyCapture()
            end
        end)
        hotkeyButton:SetScript("OnKeyDown", function(self, key)
            if not hotkeyCapturing then
                return
            end
            if MODIFIER_KEYS[key] then
                return -- wait for the actual key; modifiers are read from the keyboard state
            end
            if key == "ESCAPE" then
                StopHotkeyCapture()
                return
            end
            local binding = key
            if IsShiftKeyDown() then binding = "SHIFT-" .. binding end
            if IsControlKeyDown() then binding = "CTRL-" .. binding end
            if IsAltKeyDown() then binding = "ALT-" .. binding end
            StopHotkeyCapture()
            ApplyHotkey(binding)
            RefreshHotkeyDisplay()
        end)
        hotkeyButton:SetScript("OnHide", StopHotkeyCapture)
        hotkeyClearButton:SetScript("OnClick", ClearHotkey)
    else
        -- A client without the binding API: fall back to the standard menu.
        hotkeyHint.label:SetText(L["HOTKEY_HINT_MENU_ONLY"])
        hotkeyButton:Disable()
        hotkeyClearButton:Disable()
    end
    window:HookScript("OnShow", function()
        windowOptions:Refresh()
        destination:Refresh()
        RefreshHotkeyDisplay()
        LayoutWindow()
    end)
    windowOptions:HookScript("OnSizeChanged", function()
        if window:IsVisible() then LayoutWindow() end
    end)
    SelectPage("protection")
end
ToggleSettingsFrame = function(forceOpen, page)
    if not settingsFrame then return end
    if page then settingsFrame.SelectPage(page) end
    if ns.ProfessionViews.Open(settingsFrame) then return end
    if settingsFrame:IsShown() and not forceOpen then
        settingsFrame:Hide()
        return
    end
    if not settingsFrame:IsShown() then
        settingsFrame:ClearAllPoints()
        if mainFrame and mainFrame:IsShown() then
            settingsFrame:SetPoint("TOPRIGHT", mainFrame, "TOPLEFT", -20, -12)
        else
            settingsFrame:SetPoint("CENTER", UIParent, "CENTER", -300, 0)
        end
        settingsFrame:Show()
    end
    settingsFrame:Raise()
end


-- /sde check and /sde copy share the same plain-text report.
local checkCopyFrame
local function ShowCheckCopyWindow(text)
    if not checkCopyFrame then
        checkCopyFrame = CreateStyledWindow("Sintezza_Disenchant_CheckFrame", 500, 420)
        checkCopyFrame:SetPoint("CENTER")
        checkCopyFrame:SetFrameStrata("DIALOG")
        checkCopyFrame.title:SetText(L["CHECK_TITLE"])

        local hint = ns.InterfaceFonts:CreateText(checkCopyFrame, "OVERLAY", "GameFontNormalSmall", db)
        hint:SetPoint("TOPLEFT", 16, -55)
        hint:SetPoint("RIGHT", checkCopyFrame, "RIGHT", -16, 0)
        hint:SetJustifyH("LEFT")
        hint:SetTextColor(0.7, 0.7, 0.7)
        hint:SetText(L["CHECK_COPY_HINT"])

        local scroll = CreateFrame("ScrollFrame", "Sintezza_Disenchant_CheckScroll", checkCopyFrame, "BackdropTemplate")
        ns.SettingsTheme:AttachScrollBar(scroll, checkCopyFrame)
        scroll:SetPoint("TOPLEFT", 14, -77)
        scroll:SetPoint("BOTTOMRIGHT", -32, 14)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetAutoFocus(false)
        edit:EnableMouse(true)
        edit:SetWidth(440)
        edit:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
            checkCopyFrame:Hide()
        end)
        scroll:SetScrollChild(edit)
        checkCopyFrame.edit = edit
    end

    checkCopyFrame.edit:SetText(text)
    checkCopyFrame:Show()
    checkCopyFrame:Raise()
    checkCopyFrame.edit:HighlightText()
    checkCopyFrame.edit:SetFocus()
end

local function DescribeViewport(view, rows, count)
    if not view then return false, L["CHECK_VIEW_MISSING"] end
    local shown, visible = 0, 0
    for _, row in ipairs(rows) do
        if row:IsShown() then shown = shown + 1 end
        if row:IsVisible() then visible = visible + 1 end
    end
    local function Bounds(frame)
        if not frame then return "-" end
        local x, y, width, height = frame:GetRect()
        return tostring(x) .. "," .. tostring(y) .. " " .. tostring(width) .. "x" .. tostring(height)
    end
    local first = rows[1]
    local detail = L["CHECK_VIEW_STATE"]:format(
        view:IsShown() and 1 or 0, view:IsVisible() and 1 or 0, count, shown, visible,
        tostring(view.offset), tostring(view.range), rowsRefreshQueued and "1" or "0", Bounds(view),
        Bounds(first), first and first:IsShown() and 1 or 0, first and first:IsVisible() and 1 or 0,
        tostring(first and first:GetAlpha()), tostring(first and first.dataRevision), tostring(rowsRevision))
    return rowsRefreshQueued or not view:IsVisible() or count == 0 or visible > 0, detail
end

local function RunSelfCheck(forceWindow)
    local lines = {}
    local anyFail = false
    local function report(ok, label, detail)
        if not ok then
            anyFail = true
        end
        local suffix = detail and (" · " .. tostring(detail)) or ""
        local result = L[ok and "CHECK_OK" or "CHECK_FAIL"]
        lines[#lines + 1] = string.format("[%s] %s%s", result, label, suffix)
        local state = (ok and "|cff00ff00" or "|cffff4040") .. result .. "|r"
        Print(string.format("[%s] %s%s", state, label, suffix))
    end

    local meta
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        meta = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
    elseif GetAddOnMetadata then
        meta = GetAddOnMetadata(ADDON_NAME, "Version")
    end
    local header = L["CHECK_HEADER"]:format(meta or "1.2.0")
    lines[#lines + 1] = header
    Print(header)

    local gameVersion, build, _, tocVersion = GetBuildInfo()
    report(true, L["CHECK_CLIENT"], L["CHECK_BUILD"]:format(gameVersion, build, tocVersion))
    -- Check for actual CONTENT, not just existence: the main file guarantees
    -- an (empty) table either way, so "L exists" would still look OK even if
    -- Locales.lua never loaded - exactly the bug a missing .toc line causes.
    local clientLocale = GetLocale()
    local addonLocale = Sintezza_Theme.GetLocale and Sintezza_Theme:GetLocale() or (clientLocale == "ruRU" and "ruRU" or "enUS")
    report(L["DISENCHANT"] ~= nil, L["CHECK_LOCALE"], L["CHECK_LOCALE_INFO"]:format(addonLocale, clientLocale))

    -- Libraries
    report(minimapButton ~= nil, L["CHECK_MINIMAP"])

    -- Active API paths (shows which fallbacks this client uses)
    report(C_Container and C_Container.GetContainerItemInfo ~= nil, "C_Container API")
    local isEquippable = C_Item and C_Item.IsEquippableItem
    report(isEquippable ~= nil or IsEquippableItem ~= nil, L["CHECK_EQUIPPABLE"], L[isEquippable and "CHECK_MODERN" or "CHECK_LEGACY"])
    report(true, L["CHECK_ITEM_KEYS"], (C_Item and C_Item.GetItemGUID) and "GUID" or L["CHECK_BAG_SLOT"])
    report(true, L["CHECK_BAGS"], #BAGS_TO_SCAN .. " · " .. L[REAGENT_BAG and "CHECK_REAGENT_BAG" or "CHECK_NO_REAGENT_BAG"])

    -- Saved variables & settings
    report(type(db) == "table", "SavedVariables")
    if type(db) == "table" then
        local blacklistCount = 0
        if type(db.blacklist) == "table" then
            for _ in pairs(GetModeBlacklist()) do
                blacklistCount = blacklistCount + 1
            end
        end
        report(true, L["SETTINGS_TITLE"], L["CHECK_SETTINGS_VALUES"]:format(
            L[db.ilvlCapEnabled and "CHECK_ON" or "CHECK_OFF"], tostring(db.ilvlCap or "—"),
            blacklistCount, L[db.compactMode and "CHECK_ON" or "CHECK_OFF"]))
    end

    -- Frames
    report(mainFrame ~= nil, L["CHECK_MAIN_WINDOW"])
    report(compactFrame ~= nil, L["COMPACT_BUTTON"])
    report(settingsFrame ~= nil, L["SETTINGS_TITLE"])
    report(blacklistFrame ~= nil, L["BLACKLIST_TITLE"])
    local listOK, listDetails = DescribeViewport(listScrollFrame, listRows, #items)
    report(listOK, L["CHECK_LIST_VIEW"], listDetails)
    local queueOK, queueDetails = DescribeViewport(queueScrollFrame, queueRows, #queue)
    report(queueOK, L["CHECK_QUEUE_VIEW"], queueDetails)

    -- Value guard / price providers (v1.5.0). Only a FAIL when the guard is on
    -- but no price addon answers - then the feature would silently do nothing.
    if ns.Prices and ns.Prices.GetProviderStatus then
        local available = {}
        for _, p in ipairs(ns.Prices.GetProviderStatus()) do
            if p.available then
                available[#available + 1] = p.label
            end
        end
        local found = #available > 0 and table.concat(available, ", ") or L["CHECK_PRICES_NONE"]
        if db and db.priceWarnEnabled then
            report(#available > 0, L["CHECK_PRICES"], #available > 0 and L["CHECK_PRICE_THRESHOLD"]:format(found, db.priceThresholdGold or "—")
                or L["CHECK_PRICE_NO_SOURCE"])
        else
            report(true, L["CHECK_PRICES"], L["CHECK_PRICE_OFF"]:format(found))
        end
    end

    -- Every visible mode must resolve a spell name because the secure button
    -- casts by name. Reporting the active key makes cross-client bug reports
    -- useful once milling/prospecting join the descriptor list.
    local availableModes = GetAvailableModes()
    local availableKeys = {}
    for _, mode in ipairs(availableModes) do
        availableKeys[#availableKeys + 1] = mode.key
        report(mode.spellName() ~= nil, L["CHECK_MODE_SPELL"]:format(mode.key))
    end
    report(#availableModes > 0, L["CHECK_MODES"], L["CHECK_MODE_ACTIVE"]:format(
        table.concat(availableKeys, ", "), activeMode and activeMode.key or "—"))

    if queueButton then
        local expectedEdge = (GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")) and "AnyDown" or "AnyUp"
        report(queueButton.dehClickEdge == expectedEdge, L["CHECK_CLICK_EDGE"], expectedEdge)
    end

    -- Hotkey (1.7.0): the queue button must carry its global name, otherwise
    -- the CLICK binding from Bindings.xml has nothing to target.
    if queueButton then
        report(queueButton:GetName() == QUEUE_BUTTON_NAME, L["CHECK_QUEUE_BINDING"], QUEUE_BUTTON_NAME)
        local hk1, hk2 = nil, nil
        if GetBindingKey then
            hk1, hk2 = GetBindingKey(QUEUE_BINDING)
        end
        report(true, L["HOTKEY_HEADER"], hk1 and (FormatBindingKey(hk1) .. (hk2 and (", " .. FormatBindingKey(hk2)) or "")) or L["HOTKEY_NOT_BOUND"])
    end

    -- Live scan smoke test
    report(activeMode and activeMode.isKnown(), L["CHECK_MODE_KNOWN"], activeMode and activeMode.key or "—")
    if not InCombatLockdown() then
        ScanBags()
        -- Re-arm after the scan: ScanBags rebuilt the queue, so without this
        -- the secure attributes would lag one refresh behind - the check would
        -- compare fresh queue against stale attributes (and leave them stale).
        UpdateQueueButton()
        report(true, L["CHECK_SCAN"], L["CHECK_SCAN_COUNTS"]:format(#items, #queue, ns.waitingForItems or 0))
        if queue[1] and queueButton then
            report(queueButton:GetAttribute("type") == "spell"
                and queueButton:GetAttribute("target-bag") == queue[1].bag
                and queueButton:GetAttribute("target-slot") == queue[1].slot,
                L["CHECK_CAST_ARMED"], L["QUEUE_NEXT"]:format(queue[1].name or "—"))
        else
            report(true, L["CHECK_CAST_ARMED"], L["CHECK_CAST_IDLE"])
        end
    else
        report(false, L["CHECK_SCAN"], L["CHECK_SKIPPED_COMBAT"])
    end

    if anyFail or forceWindow then
        ShowCheckCopyWindow(table.concat(lines, "\n"))
    else
        Print(L["CHECK_ALL_OK"])
    end
end

SLASH_SINTEZZA_DISENCHANT1 = "/sde"
SLASH_SINTEZZA_DISENCHANT2 = "/sintezzadisenchant"
SLASH_SINTEZZA_DISENCHANT3 = "/standalonedisenchant"
-- Prints the command overview. Lives in its own function so both "/sde help"
-- and any unknown command can share it - before this, a typo like "/sde hilfe"
-- silently toggled the main window, which read as "the command did nothing".
local function PrintHelp()
    Print(L["HELP_HEADER"])
    Print("  /sde mail - " .. L["HELP_MAIL"])
    Print("  /sde - " .. L["HELP_TOGGLE"])
    if ns.ProfessionTab and ns.ProfessionTab.Open then Print("  /sde open - " .. L["HELP_PROF_OPEN"]) end
    Print("  /sde compact - " .. L["HELP_COMPACT"])
    Print("  /sde options - " .. L["HELP_OPTIONS"])
    Print("  /sde show | hide | reset - " .. L["HELP_MINIMAP"])
    Print("  /sde refresh - " .. L["HELP_REFRESH"])
    Print("  /sde clearblacklist - " .. L["HELP_CLEARBLACKLIST"])
    Print("  /sde check - " .. L["HELP_CHECK"])
    Print("  /sde copy - " .. L["HELP_COPY"])
    Print("  /sde de [all | copy | reset] - " .. L["HELP_LEARN"])
    Print("  /sde ev [on | off] - " .. L["HELP_EV"])
    Print("  /sde stats [reset | resetall] - " .. L["HELP_STATS"])
end

SlashCmdList.SINTEZZA_DISENCHANT = function(msg)
    msg = string.lower(strtrim(msg or ""))

    -- All branches below touch db (settings, blacklist, minimap state);
    -- one guard here beats scattered "db and ..." checks in every branch.
    if not db then
        return
    end

    if msg == "open" then
        if InCombatLockdown() then
            Print(L["NOT_IN_COMBAT"])
        elseif not (ns.ProfessionTab and ns.ProfessionTab.Open and ns.ProfessionTab.Open()) then
            Print(L["PROF_OPEN_FAILED"])
        end
        return
    elseif msg == "show" then
        db.minimap.hide = false
        if minimapButton then minimapButton:Refresh(db.minimap) end
        Print(L["MM_SHOWN"])
        return
    elseif msg == "hide" then
        db.minimap.hide = true
        if minimapButton then minimapButton:Refresh(db.minimap) end
        Print(L["MM_HIDDEN"])
        return
    elseif msg == "refresh" then
        if RefreshList() then Print(L["LIST_REFRESHED"]) else Print(L["NOT_IN_COMBAT"]) end
        return
    elseif msg == "resetbutton" or msg == "reset" then
        db.minimap.hide = false
        db.minimap.minimapPos = 220
        if minimapButton then minimapButton:Refresh(db.minimap) end
        Print(L["MM_RESET"])
        return
    elseif msg == "clearblacklist" then
        wipe(GetModeBlacklist())
        Print(L["BLACKLIST_CLEARED"])
        if RefreshBlacklistUI then
            RefreshBlacklistUI()
        end
        RefreshList()
        return
    elseif msg == "compact" then
        SetCompactMode(not db.compactMode)
        return
    elseif msg == "options" or msg == "settings" then
        ToggleSettingsFrame()
        return
    elseif msg == "mail" then
        ns.MailUI.Toggle()
        return
    elseif msg == "check" then
        RunSelfCheck(false)
        return
    elseif msg == "copy" then
        RunSelfCheck(true)
        return
    elseif msg == "de" or string.sub(msg, 1, 3) == "de " then
        local arg = strtrim(string.sub(msg, 3))
        if not ns.Learn then
            return
        elseif arg == "reset" then
            ToggleStatsFrame()
            OpenStatsData(true)
        elseif arg == "copy" then
            ShowCheckCopyWindow(table.concat(ns.Learn.BuildReport(true), "\n"))
        else
            for _, line in ipairs(ns.Learn.BuildReport(arg == "all")) do
                Print(line)
            end
        end
        return
    elseif msg == "stats" or string.sub(msg, 1, 6) == "stats " then
        local arg = strtrim(string.sub(msg, 6))
        if not ns.Stats then
            return
        elseif arg == "reset" or arg == "resetall" then
            ToggleStatsFrame()
            OpenStatsData(true)
        else
            ToggleStatsFrame()
        end
        return
    elseif msg == "ev" or string.sub(msg, 1, 3) == "ev " then
        local arg = strtrim(string.sub(msg, 3))
        if arg == "on" then
            db.showExpected = true
        elseif arg == "off" then
            db.showExpected = false
        else
            db.showExpected = not (db.showExpected ~= false)
        end
        Print(db.showExpected ~= false and L["EV_TOGGLE_ON"] or L["EV_TOGGLE_OFF"])
        RefreshUI()
        return
    elseif msg == "help" or msg == "?" then
        PrintHelp()
        return
    elseif msg ~= "" then
        -- Unknown command: explain instead of silently toggling the window
        PrintHelp()
        return
    end

    ToggleMainFrame()
end

function ns.RegisterEscapeHandling()
    local names = {
        "Sintezza_Disenchant_CheckFrame",
        "Sintezza_Disenchant_SettingsFrame",
        "Sintezza_Disenchant_BlacklistFrame",
        "Sintezza_Disenchant_MailFrame",
        "Sintezza_Disenchant_CompactFrame",
        "Sintezza_Disenchant_MainFrame",
    }
    -- Registering a handler directly can taint Forever's protected Escape actions.
    function ns.UpdateEscapeWindows()
        if type(UISpecialFrames) ~= "table" then return end
        for index = #UISpecialFrames, 1, -1 do
            for _, name in ipairs(names) do
                if UISpecialFrames[index] == name then
                    table.remove(UISpecialFrames, index)
                    break
                end
            end
        end
        if InCombatLockdown() or ns.ProfessionViews.page then return end
        for _, name in ipairs(names) do UISpecialFrames[#UISpecialFrames + 1] = name end
    end
    ns.UpdateEscapeWindows()
end

addon:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName == "Baganator" and mainFrame and IsLoggedIn() then
            ns.Style.RegisterBagButton(ToggleMainFrame)
        end
        if loadedName ~= ADDON_NAME then
            return
        end
        EnsureDB()
        ns.MailUI.Init(db, CreateStyledWindow)
        ns.ExternalTooltips.Init(db)
        if ns.Learn then
            ns.Learn.spellID = SPELL_ID_DISENCHANT
            pcall(ns.Learn.Init, db)
        end
        if ns.Stats then
            pcall(ns.Stats.Init, db)   -- after Learn.Init: backfills from learned data
        end
        if (ns.Learn and ns.Learn.storageBlocked) or (ns.Stats and ns.Stats.storageBlocked) then
            Print(L["STORAGE_BLOCKED"])
        end
        ApplyMode(db.activeMode)
        CreateMainFrame()
        windowAppearance:Bind(mainFrame, {
            active = function() return not ns.ProfessionViews.page end,
            resize = { minWidth = 860, minHeight = 460, maxWidth = 1380, maxHeight = 960 },
        })
        CreateMinimapButton()
        CreateCompactFrame()
        CreateSettingsFrame()
        ns.RegisterEscapeHandling()
        windowAppearance:Bind(settingsFrame, {
            resetX = -300,
            active = function()
                local view = ns.ProfessionViews.current
                return not view or view.frame ~= settingsFrame
            end,
            resize = {
                minWidth = 490, minHeight = 410, maxWidth = 920, maxHeight = 960,
            },
        })
        ns.Launcher:RegisterSettings("Sintezza Disenchant", function() ToggleSettingsFrame(true) end)
        if ns.ProfessionTab and not _G.DisenchantHelper_MainFrame then
            ns.ProfessionTab.Init(mainFrame, RefreshList, function()
                if compactFrame:IsShown() then compactFrame:Hide() end
                DockQueueButtonToPanel()
            end, function(page)
                local embedded = page ~= nil
                if not embedded then ns.ProfessionViews.Restore() end
                ns.ProfessionViews.page = page
                if ns.UpdateEscapeWindows then ns.UpdateEscapeWindows() end
                if not embedded then windowAppearance:ApplyTo(mainFrame) end
                mainFrame.professionContent = embedded
                mainContent:LayoutListFooter()
                mainFrame:EnableMouse(not embedded)
                mainFrame:SetToplevel(not embedded)
                mainFrame.TitleBar:SetShown(not embedded)
                modeTabFrame:ClearAllPoints()
                modeTabFrame:SetPoint("TOPLEFT", mainContent, "TOPLEFT", 16, embedded and -37 or -53)
                mainContent.settingsButton:ClearAllPoints()
                if embedded then
                    mainFrame.title:SetPoint("RIGHT", mainFrame.CloseButton, "LEFT", -12, 0)
                    mainContent.settingsButton:SetPoint("TOPRIGHT", mainContent, "TOPRIGHT", -30, -7)
                else
                    mainContent.settingsButton:SetPoint("RIGHT", mainFrame.CloseButton, "LEFT", -8, 0)
                end
                mainContent.heading:SetShown(embedded)
                if embedded then
                    -- The native page owns the controls. Only the secure cast
                    -- button stays on the independent combat-hide frame.
                    queueButton:SetParent(mainFrame)
                    queueButton:ClearAllPoints()
                    queueButton.professionX, queueButton.professionY, queueButton.professionScale = nil, nil, nil
                    queueButton:Hide()
                    -- Keep the secure root and its cast button together above
                    -- the page; the root has no backdrop or mouse hit area.
                    queueButton.professionPreviousStrata = queueButton:GetFrameStrata()
                    local above = {BACKGROUND="LOW", LOW="MEDIUM", MEDIUM="HIGH", HIGH="DIALOG",
                        DIALOG="FULLSCREEN", FULLSCREEN="FULLSCREEN_DIALOG", FULLSCREEN_DIALOG="TOOLTIP"}
                    local pageStrata = page:GetFrameStrata()
                    local actionStrata = above[pageStrata] or pageStrata
                    mainFrame:SetFrameStrata(actionStrata)
                    queueButton:SetFrameStrata(actionStrata)
                    queueButton:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
                    mainContent:ClearAllPoints()
                    mainContent:SetParent(page)
                    mainContent:SetAllPoints(page)
                    mainContent:SetFrameStrata(page:GetFrameStrata())
                    mainContent:SetFrameLevel(page:GetFrameLevel() + 1)
                    mainFrame:SetBackdrop(nil)
                    mainFrame.chrome:Hide()
                else
                    mainContent:ClearAllPoints()
                    mainContent:SetParent(mainFrame)
                    mainContent:SetAllPoints(mainFrame)
                    mainContent:SetFrameStrata(mainFrame:GetFrameStrata())
                    mainContent:SetFrameLevel(mainFrame:GetFrameLevel() + 1)
                    mainContent:AnchorMainTitle()
                    DockQueueButtonToPanel()
                    if queueButton.professionPreviousStrata then
                        queueButton:SetFrameStrata(queueButton.professionPreviousStrata)
                        queueButton.professionPreviousStrata = nil
                    end
                    queueButton:SetFrameLevel(queuePanel:GetFrameLevel() + 1)
                    queueButton:Show()
                    ns.Style.Window(mainFrame)
                end
            end, ns.ProfessionViews.SyncAction)
        end
    elseif event == "PLAYER_LOGIN" then
        ns.Style.RegisterBagButton(ToggleMainFrame)
        RefreshList()
    elseif event == "BAG_UPDATE_DELAYED" then
        local anyShown = (mainFrame and mainFrame:IsShown()) or (compactFrame and compactFrame:IsShown())
        if anyShown then
            if InCombatLockdown() then
                -- Cannot rescan now (secure attributes are locked), but do NOT
                -- drop the update: loot during combat would otherwise leave the
                -- list AND the armed bag/slot target stale after combat ends.
                needsRefreshAfterCombat = true
            else
                RefreshList()
            end
        end
    elseif event == "UI_ERROR_MESSAGE" or event == "UI_INFO_MESSAGE" or event == "CHAT_MSG_SYSTEM" then
        local item = pendingDisenchantItem
        if item then
            local elapsed = GetTime() - item.startedAt
            if elapsed > (item.castGUID and 8 or 0.5) then return end

            local message = ExtractMessageFromEventArgs(...)
            local errorIndex = ...
            local errorName
            if event ~= "CHAT_MSG_SYSTEM" and GetGameMessageInfo
                and not IsSecretValue(errorIndex) and type(errorIndex) == "number" then
                errorName = GetGameMessageInfo(errorIndex)
                if IsSecretValue(errorName) then errorName = nil end
            end
            local failureType = activeMode.classifyFailure(message, errorName)
            if failureType then
                item.refused = item.refused or failureType == "hard"
                item.reason = message or item.reason
                ResolvePendingDisenchant()
            end
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_SENT"
        or event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET"
        or event == "UNIT_SPELLCAST_INTERRUPTED" then
        local unit, guid, spellID = ...
        if event == "UNIT_SPELLCAST_SENT" then
            guid, spellID = select(3, ...)
        end
        if IsSecretValue(unit) or unit ~= "player" or IsSecretValue(spellID) then return end

        local item = pendingDisenchantItem
        if item and spellID == SPELL_ID_DISENCHANT and not IsSecretValue(guid)
            and type(guid) == "string" and guid ~= "" then
            local elapsed = GetTime() - item.startedAt
            if not item.castGUID and elapsed <= 0.5
                and (event == "UNIT_SPELLCAST_SENT" or event == "UNIT_SPELLCAST_START") then
                item.castGUID = guid
            end
            if item.castGUID == guid and elapsed <= 8 then
                if event == "UNIT_SPELLCAST_SUCCEEDED" then
                    ClearPendingDisenchant()
                elseif event ~= "UNIT_SPELLCAST_SENT" and event ~= "UNIT_SPELLCAST_START" then
                    ResolvePendingDisenchant()
                end
            end
        end

        if ns.Learn then
            if event == "UNIT_SPELLCAST_SENT" or event == "UNIT_SPELLCAST_START" then
                pcall(ns.Learn.OnCastSent, spellID, guid)
            elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
                pcall(ns.Learn.OnCastSucceeded, spellID, guid)
            elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET"
                or event == "UNIT_SPELLCAST_INTERRUPTED" then
                pcall(ns.Learn.OnCastFailed, spellID, guid)
            end
        end
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        if ns.Learn then
            pcall(ns.Learn.OnLoot)
        end
    elseif event == "CVAR_UPDATE" then
        local key = ...
        if type(key) == "string" and key:lower() == "actionbuttonusekeydown" then
            UpdateQueueButtonClickRegistration()
        end
    elseif event == "UPDATE_BINDINGS" then
        -- The user may (re)bind the key in the client's Key Bindings window.
        RefreshHotkeyDisplay()
    elseif event == "PLAYER_REGEN_DISABLED" then
        if ns.UpdateEscapeWindows then ns.UpdateEscapeWindows() end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if ns.UpdateEscapeWindows then ns.UpdateEscapeWindows() end
        if db and db.compactMode and compactFrame and compactFrame:IsShown() and queueButton and queueButton:GetParent() ~= compactFrame then
            DockQueueButtonToCompact()
        end
        if needsRefreshAfterCombat then
            -- Bags changed during combat: full rescan (also re-arms the button).
            needsRefreshAfterCombat = false
            RefreshList()
        else
            UpdateQueueButton()
        end
        -- If we loaded during combat (/reload), the auto-hide driver could not
        -- be registered yet; do it now that we are out of combat.
        EnsureMainCombatHideDriver()
    end
end)

addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_LOGIN")
addon:RegisterEvent("BAG_UPDATE_DELAYED")
addon:RegisterEvent("UI_ERROR_MESSAGE")
addon:RegisterEvent("UI_INFO_MESSAGE")
addon:RegisterEvent("CHAT_MSG_SYSTEM")
addon:RegisterEvent("PLAYER_REGEN_DISABLED")
addon:RegisterEvent("PLAYER_REGEN_ENABLED")
addon:RegisterEvent("UPDATE_BINDINGS")
addon:RegisterEvent("CVAR_UPDATE")
addon:RegisterEvent("LOOT_OPENED")
pcall(addon.RegisterEvent, addon, "LOOT_READY")
if addon.RegisterUnitEvent then
    addon:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
else
    addon:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end
-- Optional attribution events: retain the existing success-only path if absent.
pcall(addon.RegisterEvent, addon, "UNIT_SPELLCAST_SENT")
pcall(addon.RegisterEvent, addon, "UNIT_SPELLCAST_START")
pcall(addon.RegisterEvent, addon, "UNIT_SPELLCAST_STOP")
pcall(addon.RegisterEvent, addon, "UNIT_SPELLCAST_FAILED")
pcall(addon.RegisterEvent, addon, "UNIT_SPELLCAST_FAILED_QUIET")
pcall(addon.RegisterEvent, addon, "UNIT_SPELLCAST_INTERRUPTED")
