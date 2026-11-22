local _, ns = ...
local tabUI = { Icon = Sintezza_Theme.icons.DisenchantProfession }
ns.ProfessionTab = tabUI

-- Use the existing helper and secure processing button. Keep their parent
-- unchanged so Blizzard's professions frame does not inherit protection.
function tabUI.Init(helper, refresh, prepare, styleContent, syncAction)
    if ns.EraReference.Client() ~= "forever" then return end
    local watcher = CreateFrame("Frame")
    local book, tab, page, original, shortcut, portrait
    local shortcutBorder, bronzeFallback
    local pageActive, closing = false, false
    local hooked = {}
    local concealed = {}
    local iconPath = tabUI.Icon
    local macroNames, macroBody = {"SDE: Professions", "SDE Shortcut", "SDE Shortcut 2", "SDE Shortcut 3"}, "/sde open"
    local macroIcon = 135952 -- Built-in Disenchant spell icon, not an addon texture.
    local openPage
    local syncShortcut
    local moving, wasClamped = false, nil

    local function stopMoving()
        if not moving or InCombatLockdown() then return end
        moving = false
        book:StopMovingOrSizing()
        book:SetMovable(false)
        if wasClamped ~= nil then book:SetClampedToScreen(wasClamped) end
        wasClamped = nil
    end

    local function pickupShortcut()
        if InCombatLockdown() or not GetCursorInfo or GetCursorInfo() ~= nil then return end
        local indexByName = GetMacroIndexByName or (C_Macro and C_Macro.GetMacroIndexByName)
        local macroInfo = GetMacroInfo
        local pickup = PickupMacro or (C_Macro and C_Macro.PickupMacro)
        if not (indexByName and macroInfo and pickup) then return "PROF_MACRO_FAILED" end
        local index, freeName
        for _, name in ipairs(macroNames) do
            local found = indexByName(name)
            if found and found > 0 then
                local _, texture, savedBody = macroInfo(found)
                local body = (GetMacroBody and GetMacroBody(found)) or savedBody
                if texture == macroIcon and type(body) == "string" and body:match("^%s*(.-)%s*$") == macroBody then
                    index = found
                    break
                end
            else
                freeName = freeName or name
            end
        end
        if not index then
            if not freeName or not CreateMacro then return "PROF_MACRO_FAILED" end
            local ok, created = pcall(CreateMacro, freeName, macroIcon, macroBody, false)
            if not ok or type(created) ~= "number" or created <= 0 then return "PROF_MACRO_FAILED" end
            index = created
        end
        local ok = pcall(pickup, index)
        if not ok or GetCursorInfo() ~= "macro" then return "PROF_MACRO_FAILED" end
    end

    local function selectTab(checked)
        tab:SetChecked(checked)
        tab.Icon:SetTexture(iconPath)
    end

    local function leaveTraining()
        local trainingPage = _G.WhatsTrainingCraftingPage
        if not (trainingPage and trainingPage:IsVisible()) then return true end
        -- Use the other addon's own return action; do not alter its frames,
        -- private state, or Blizzard's selected profession ourselves.
        local returnTab = _G.WhatsTrainingCraftingReturnTab
        local mouseUp = returnTab and returnTab:IsVisible() and returnTab:GetScript("OnMouseUp")
        if mouseUp then mouseUp(returnTab, "LeftButton", true) end
        return not trainingPage:IsVisible()
    end

    local function conceal(region)
        if region and concealed[region] == nil then
            concealed[region] = region:GetAlpha()
            region:SetAlpha(0)
        end
    end

    local function concealRecipeValues()
        local detail = _G.ForeverGuideProfDetail
        local overlay = detail and detail:GetParent()
        if overlay and overlay.detail == detail and overlay:GetParent() == UIParent then
            conceal(overlay)
        end
    end

    local function leavePage()
        if not pageActive then return end
        pageActive = false
        for region, alpha in pairs(concealed) do
            region:SetAlpha(alpha)
            concealed[region] = nil
        end
        page:Hide()
        if portrait then portrait:Hide() end
        selectTab(false)
        if syncShortcut then syncShortcut() end
    end

    local function restore()
        if not original or InCombatLockdown() then return end
        local state = original
        original = nil
        helper:ClearAllPoints()
        for _, point in ipairs(state.points) do helper:SetPoint(unpack(point, 1, 5)) end
        helper:SetSize(state.width, state.height)
        helper:SetFrameStrata(state.strata)
        helper:SetFrameLevel(state.level)
        helper:SetMovable(state.movable)
        styleContent(nil)
    end

    local function close()
        if not original or closing then return end
        closing = true
        -- Restore native UI independently of the secure helper's hide event.
        leavePage()
        if not InCombatLockdown() then
            if helper:IsShown() then helper:Hide() end
            restore()
        end
        closing = false
    end

    local function fit()
        if not pageActive or not original or InCombatLockdown() then return end
        local x, y, width, height = page:GetRect()
        if not x or not y or not width or not height or width <= 0 or height <= 0 then return end
        local ratio = page:GetEffectiveScale() / helper:GetEffectiveScale()
        x, y, width, height = x * ratio, y * ratio, width * ratio, height * ratio
        if x == original.x and y == original.y and width == original.fitWidth and height == original.fitHeight then return end
        local sizeChanged = width ~= original.fitWidth or height ~= original.fitHeight
        original.x, original.y, original.fitWidth, original.fitHeight = x, y, width, height
        helper:ClearAllPoints()
        helper:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
        if sizeChanged then
            helper:SetSize(width, height)
            refresh()
        end
    end

    local function position()
        local training = _G.WhatsTrainingCraftingTab
        local bottom = book:GetBottom()
        local lowest = book.ProfessionsOverviewTab:GetBottom()
        for _, native in ipairs(book.rightProfessionTabs) do
            if native:IsShown() and native:GetBottom() then
                lowest = math.min(lowest or native:GetBottom(), native:GetBottom())
            end
        end
        tab:ClearAllPoints()
        local trainingTop = training and training:IsShown() and training:GetTop()
        local trainingLeft = trainingTop and training:GetLeft()
        local bookRight = book:GetRight()
        local sideSlot = trainingLeft and bookRight and math.abs(trainingLeft - bookRight) < 12
        local top = sideSlot and trainingTop or (bottom and bottom + 10)
        if lowest and top and lowest < top + tab:GetHeight() + 4 then
            tab:SetPoint("TOPLEFT", book, "BOTTOMRIGHT", -4, -2)
        elseif sideSlot then
            tab:SetPoint("BOTTOMLEFT", training, "TOPLEFT", 0, 2)
        else
            tab:SetPoint("BOTTOMLEFT", book, "BOTTOMRIGHT", -4, 10)
        end
        if training and not hooked[training] then
            hooked[training] = true
            training:HookScript("OnMouseUp", function(_, button, inside)
                if button == "LeftButton" and inside then close() end
            end)
            training:HookScript("OnShow", position)
            training:HookScript("OnHide", position)
        end
        local trainingPage = _G.WhatsTrainingCraftingPage
        if trainingPage and not hooked[trainingPage] then
            hooked[trainingPage] = true
            trainingPage:HookScript("OnShow", syncShortcut)
            trainingPage:HookScript("OnHide", syncShortcut)
        end
        syncShortcut()
    end

    local function displaysName(frame, names, depth)
        if not frame or not frame:IsShown() then return false end
        for _, region in ipairs({frame:GetRegions()}) do
            if region:IsObjectType("FontString") and region:IsShown() then
                local text = region:GetText()
                if type(text) == "string" and not (issecretvalue and issecretvalue(text)) and names[text] then return frame end
            end
        end
        if depth > 0 then
            for _, child in ipairs({frame:GetChildren()}) do
                local match = displaysName(child, names, depth - 1)
                if match then return match end
            end
        end
        return false
    end

    local function matchShortcutBorder(card, spellRow)
        local function apply(texture)
            if not texture or not texture.GetAtlas or not texture.GetTexture then return false end
            local atlas = texture:GetAtlas()
            local file = texture:GetTexture()
            if atlas then
                shortcutBorder:SetAtlas(atlas)
            elseif file and texture.GetTexCoord then
                shortcutBorder:SetTexture(file)
                shortcutBorder:SetTexCoord(texture:GetTexCoord())
            else
                return false
            end
            shortcutBorder:SetVertexColor(texture:GetVertexColor())
            shortcutBorder:Show()
            bronzeFallback:Hide()
            return true
        end
        local function tryButton(button)
            if not button then return false end
            if apply(button.IconBorder) then return true end
            for _, region in ipairs({button:GetRegions()}) do
                if region:IsObjectType("Texture") and region:IsShown() then
                    local atlas = region:GetAtlas()
                    if atlas then
                        local name = atlas:lower()
                        if (name:find("border",1,true) or name:find("iconframe",1,true))
                            and apply(region) then return true end
                    end
                end
            end
            return false
        end
        shortcutBorder:Hide()
        bronzeFallback:Show()
        if spellRow and spellRow ~= card and tryButton(spellRow) then return end
        if tryButton(card.SpellButton1) then return end
        tryButton(card.SpellButton2)
    end

    syncShortcut = function()
        local trainingPage = _G.WhatsTrainingCraftingPage
        local content = book.BookPage.ProfessionsContentFrame
        local card, spellRow
        if content and not pageActive and book.BookPage:IsVisible() and not (trainingPage and trainingPage:IsVisible()) then
            local names = {}
            for _, spellID in ipairs({7411, 13262}) do
                local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID))
                    or (GetSpellInfo and GetSpellInfo(spellID))
                if name then names[name] = true end
            end
            local first, second = content.PrimaryProfession1, content.PrimaryProfession2
            local firstMatch = displaysName(first, names, 5)
            local secondMatch = displaysName(second, names, 5)
            if firstMatch then card, spellRow = first, firstMatch
            elseif secondMatch then card, spellRow = second, secondMatch
            elseif GetProfessions and GetProfessionInfo then
                local p1, p2 = GetProfessions()
                if p1 and select(7, GetProfessionInfo(p1)) == 333 then card = first
                elseif p2 and select(7, GetProfessionInfo(p2)) == 333 then card = second end
            end
        end
        if not card or not card:IsVisible() then shortcut:Hide(); return end
        matchShortcutBorder(card, spellRow)
        shortcut:SetFrameLevel(card:GetFrameLevel() + 12)
        shortcut:ClearAllPoints()
        if card.StatusBar then
            shortcut:SetPoint("TOPLEFT", card.StatusBar, "BOTTOMLEFT", -20, -11)
        else
            shortcut:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 150, 9)
        end
        shortcut:Show()
    end

    local function refreshShortcut()
        syncShortcut()
        -- The native page can be shown before its profession cards are filled.
        if C_Timer and C_Timer.After then C_Timer.After(0, syncShortcut) end
    end

    local function attach()
        if tab or InCombatLockdown() then return end
        local host = _G.ProfessionsFrame
        if not (host and host.BookPage and host.CraftingPage and host.ProfessionsOverviewTab
            and type(host.rightProfessionTabs) == "table") then return end
        book = host
        local portraitContainer = book.PortraitContainer
        if portraitContainer and portraitContainer.portrait and portraitContainer.CircleMask then
            portrait = portraitContainer:CreateTexture(nil, "OVERLAY", nil, 7)
            portrait:SetAllPoints(portraitContainer.portrait)
            portrait:SetTexture(ns.Icon)
            portrait:AddMaskTexture(portraitContainer.CircleMask)
            portrait:Hide()
        end
        -- A page of the professions panel, not a second movable window.
        -- Its native border, portrait, close button and neighboring tabs stay intact.
        page = CreateFrame("Frame", nil, book)
        page:SetPoint("TOPLEFT", book, "TOPLEFT", 9, -47)
        page:SetPoint("BOTTOMRIGHT", book, "BOTTOMRIGHT", -9, 9)
        -- Invisible native crafting widgets can still receive mouse input.
        -- Keep the entire DEH viewport above their HIGH-strata controls.
        page:SetFrameStrata("DIALOG")
        page:EnableMouse(true)
        page:SetFrameLevel(book:GetFrameLevel() + 8)
        page:SetScript("OnUpdate", function()
            -- ForeverGuide can create its separate overlay after the tab opens.
            if pageActive then concealRecipeValues() end
            fit()
            if syncAction then syncAction() end
        end)
        page:SetScript("OnHide", function()
            if pageActive then close() end
        end)
        local background = page:CreateTexture(nil, "BACKGROUND")
        background:SetColorTexture(0.13, 0.105, 0.08, 1)
        background:SetAllPoints()
        if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("Profession-Background-Overview") then
            local art = page:CreateTexture(nil, "BORDER")
            art:SetAllPoints()
            art:SetAtlas("Profession-Background-Overview")
        end
        page:Hide()
        tab = CreateFrame("Frame", nil, book, "LargeSideTabButtonTemplate")
        tab:EnableMouse(true)
        tab:SetFillToInterior(true)
        selectTab(false)
        tab:SetSize(book.ProfessionsOverviewTab:GetWidth(), book.ProfessionsOverviewTab:GetHeight())
        tab:SetFrameLevel(book:GetFrameLevel() + 10)
        tab.tooltipText = "Sintezza Disenchant"
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Sintezza Disenchant")
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
        shortcut = CreateFrame("Button", nil, book.BookPage)
        shortcut:SetSize(162, 40)
        local icon = shortcut:CreateTexture(nil, "ARTWORK")
        icon:SetSize(38, 38)
        icon:SetPoint("LEFT", 0, 0)
        icon:SetTexture(iconPath)
        shortcutBorder = shortcut:CreateTexture(nil, "OVERLAY")
        shortcutBorder:SetSize(40, 40)
        shortcutBorder:SetPoint("CENTER", icon, "CENTER")
        bronzeFallback = CreateFrame("Frame", nil, shortcut, "BackdropTemplate")
        bronzeFallback:SetSize(40, 40)
        bronzeFallback:SetPoint("CENTER", icon, "CENTER")
        bronzeFallback:SetBackdrop({edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 9})
        bronzeFallback:SetBackdropBorderColor(0.82, 0.63, 0.40, 1)
        local label = shortcut:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", icon, "RIGHT", 8, 6)
        label:SetText("Sintezza Disenchant")
        shortcut:SetScript("OnEnter", function(self)
            label:SetTextColor(1, 0.92, 0.60)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Sintezza Disenchant")
            GameTooltip:AddLine(ns.L["PROF_DRAG_SHORTCUT"], 1, 1, 1, true)
            GameTooltip:Show()
        end)
        shortcut:SetScript("OnLeave", function()
            label:SetTextColor(1, 0.82, 0)
            GameTooltip:Hide()
        end)
        shortcut:RegisterForDrag("LeftButton")
        shortcut:SetScript("OnDragStart", function()
            local reason = pickupShortcut()
            if reason and DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("Sintezza Disenchant: " .. ns.L[reason])
            end
        end)
        tab:SetCustomOnMouseUpHandler(function(self, button, inside)
            if button ~= "LeftButton" or not inside or InCombatLockdown() then return end
            if original then close(); return end
            openPage()
        end)
        openPage = function()
            if pageActive then return true end
            if original or not book:IsVisible() or not leaveTraining() then return false end
            page:Show()
            local x, _, width, height = page:GetRect()
            if not x or not width or not height or width <= 0 or height <= 0 then page:Hide(); return false end
            original = {
                points = {}, width = helper:GetWidth(), height = helper:GetHeight(),
                strata = helper:GetFrameStrata(), level = helper:GetFrameLevel(),
                movable = helper:IsMovable(),
            }
            pageActive = true
            if portrait then
                conceal(portraitContainer.portrait)
                portrait:Show()
            end
            syncShortcut()
            for i = 1, helper:GetNumPoints() do original.points[i] = {helper:GetPoint(i)} end
            helper:SetMovable(false)
            conceal(book.BookPage)
            conceal(book.CraftingPage)
            concealRecipeValues()
            conceal(book.ProfessionsOverviewTab.SelectedTexture)
            for _, native in ipairs(book.rightProfessionTabs) do conceal(native.SelectedTexture) end
            helper:SetFrameStrata(book:GetFrameStrata())
            helper:SetFrameLevel(book:GetFrameLevel() + 20)
            prepare()
            styleContent(page)
            helper:Show()
            fit()
            selectTab(true)
            return true
        end
        helper:HookScript("OnHide", function()
            if original and not closing then
                leavePage()
                restore()
            end
        end)
        local function hookNative(native)
            if hooked[native] then return end
            hooked[native] = true
            native:HookScript("OnMouseUp", function(_, button)
                if button == "LeftButton" then close() end
            end)
        end
        local function sync()
            hookNative(book.ProfessionsOverviewTab)
            for _, native in ipairs(book.rightProfessionTabs) do hookNative(native) end
            position()
        end
        local function reopen()
            close()
            sync()
            refreshShortcut()
        end
        book:HookScript("OnShow", reopen)
        book:HookScript("OnHide", close)
        book.BookPage:HookScript("OnShow", close)
        book.CraftingPage:HookScript("OnShow", close)
        book:HookScript("OnHide", stopMoving)
        book:HookScript("OnSizeChanged", function() sync(); fit() end)
        book.BookPage:HookScript("OnShow", refreshShortcut)
        -- Only the title strip handles dragging; leave the portrait, close
        -- button, and Blizzard's panel management untouched.
        local drag = CreateFrame("Frame", nil, book)
        drag:SetPoint("TOPLEFT", book, "TOPLEFT", 70, -7)
        drag:SetPoint("TOPRIGHT", book, "TOPRIGHT", -42, -7)
        drag:SetHeight(22)
        drag:SetFrameLevel(book:GetFrameLevel() + 35)
        local function hasOtherDrag()
            local title = book.TitleContainer
            return book:IsMovable() or book:GetScript("OnDragStart")
                or (title and title.GetScript and title:GetScript("OnDragStart"))
        end
        local mouseEnabled
        local function syncDrag()
            -- Recheck while visible so later-loaded addons can take over.
            local enabled = moving or (not InCombatLockdown() and not hasOtherDrag())
            if enabled ~= mouseEnabled then
                drag:EnableMouse(enabled)
                mouseEnabled = enabled
            end
        end
        drag:SetScript("OnShow", syncDrag)
        drag:SetScript("OnUpdate", syncDrag)
        syncDrag()
        drag:RegisterForDrag("LeftButton")
        drag:SetScript("OnDragStart", function()
            if moving or not book:IsVisible() or InCombatLockdown() or hasOtherDrag() then return end
            book:SetMovable(true)
            if book.IsClampedToScreen then
                wasClamped = book:IsClampedToScreen()
                book:SetClampedToScreen(true)
            end
            book:StartMoving()
            moving = true
        end)
        drag:SetScript("OnDragStop", stopMoving)
        drag:SetScript("OnHide", stopMoving)
        if EventRegistry and EventRegistry.RegisterCallback then
            EventRegistry:RegisterCallback("ProfessionsFrame.Show", reopen, tab)
            EventRegistry:RegisterCallback("ProfessionsFrame.Hide", close, tab)
            EventRegistry:RegisterCallback("Professions.ProfessionSelected", function() close(); sync(); refreshShortcut() end, tab)
            EventRegistry:RegisterCallback("Professions.ShowSelectedCraftingPage", function() close(); sync(); refreshShortcut() end, tab)
        end
        sync()
    end

    function tabUI.Open()
        if InCombatLockdown() then return false end
        if not _G.ProfessionsFrame then
            local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
            if load then pcall(load, "Blizzard_Professions") end
        end
        attach()
        if not book then return false end
        if not book:IsVisible() and ShowUIPanel then ShowUIPanel(book) end
        return openPage()
    end

    function tabUI.Toggle()
        if InCombatLockdown() then return false end
        if pageActive then
            close()
            if HideUIPanel and book:IsVisible() then HideUIPanel(book) end
            return true
        end
        return tabUI.Open()
    end

    watcher:RegisterEvent("ADDON_LOADED")
    watcher:RegisterEvent("PLAYER_LOGIN")
    watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    watcher:RegisterEvent("PLAYER_REGEN_DISABLED")
    watcher:RegisterEvent("SKILL_LINES_CHANGED")
    watcher:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then close(); return end
        if event == "PLAYER_REGEN_ENABLED" then stopMoving() end
        if event == "PLAYER_REGEN_ENABLED" and original then
            if not pageActive or not helper:IsShown() or not book:IsVisible() then close() end
        end
        if tab then position() else attach() end
    end)
    attach()
end
