local addonName, ns = ...
local T = ns.SettingsTheme
local Style = {}
ns.Style = Style

function Style.PaintButton(button) T:PaintButton(button) end

function Style.Button(parent, name, secure)
    local template = secure and "BackdropTemplate,SecureActionButtonTemplate,SecureHandlerStateTemplate" or "BackdropTemplate"
    local button = CreateFrame("Button", name, parent, template)
    local text = button:CreateFontString(nil, "OVERLAY")
    text:SetPoint("LEFT", button, "LEFT", 3, 0)
    text:SetPoint("RIGHT", button, "RIGHT", -3, 0)
    text:SetJustifyH("CENTER")
    button:SetFontString(text)
    button.primary = secure
    T:SkinButton(button, text)
    return button
end

function Style.Window(frame)
    frame.chrome = T:WindowSurface(frame)
end

function Style.CheckButton(parent, size)
    local check = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
    check:SetSize(size, size)
    T:SkinCheckButton(check, size - 2)
    return check
end

function Style.Panel(frame)
    T:PanelSurface(frame)
end

function Style.ProfessionLauncher(parent, name, tooltip, open, template)
    local button = CreateFrame("Button", name, parent, template or "BackdropTemplate")
    button:SetSize(32, 22)
    button.tooltipHeader = tooltip
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER")
    icon:SetSize(16, 16)
    icon:SetTexture(Sintezza_Theme.icons.DisenchantProfession)
    icon:SetTexCoord(.12, .88, .12, .88)
    icon:SetDesaturated(true)
    icon:SetVertexColor(1, .88, .42)
    -- The source art has a black background. Additive blending keeps only the shard.
    icon:SetBlendMode("ADD")
    button.Icon = icon
    button:SetScript("OnClick", open)
    if not template then
        T:SkinButton(button)
        if button.SetMotionScriptsWhileDisabled then button:SetMotionScriptsWhileDisabled(true) end
        button:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tooltipHeader)
            if not self:IsEnabled() then GameTooltip:AddLine(ns.L.NOT_IN_COMBAT, 1, .82, 0, true) end
            GameTooltip:Show()
        end)
        local function HideTooltip(self)
            if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
        end
        button:HookScript("OnLeave", HideTooltip)
        button:HookScript("OnHide", HideTooltip)
    end
    return button
end

local bagButton
function Style.RegisterBagButton(open)
    local api = Baganator and Baganator.API
    if bagButton or not api or type(api.RegisterRegion) ~= "function" then return end
    local button = Style.ProfessionLauncher(UIParent, nil, ns.L.BAG_BUTTON, open, "BaganatorTooltipIconButtonTemplate")
    api.RegisterRegion("Sintezza Disenchant", addonName, "backpack", "bottom_left", button)
    bagButton = button
    -- Baganator installs its active skinner during PLAYER_LOGIN.
    C_Timer.After(0, function()
        local skins = Baganator.Skins
        if skins and skins.AddFrame then skins.AddFrame("IconButton", button, {}) end
        if api.RequestLayoutUpdate then api.RequestLayoutUpdate() end
    end)
end

local blizzardBagButtons = {}
local function AttachBlizzardBagButton(bag, open)
    local money = bag and bag.MoneyFrame
    if not money or blizzardBagButtons[bag] then return end
    local button = Style.ProfessionLauncher(money, nil, ns.L.BAG_BUTTON, open)
    button:SetSize(18, 16)
    button.Icon:SetSize(14, 14)
    button:SetPoint("LEFT", money, "LEFT", 2, 0)
    blizzardBagButtons[bag] = button
end

local ellesmereHooked, ellesmereBagButton
local function AttachEllesmereBagButton(bags, open)
    local header, search = bags.Header, bags._searchBox
    if not header or not search then return end
    local points = search:GetNumPoints()
    if points ~= 1 and points ~= 2 then return end
    local point, relative, anchor, x, y = search:GetPointByName("RIGHT")
    if canaccessallvalues and not canaccessallvalues(point, relative, anchor, x, y) then return end
    if point ~= "RIGHT" then return end

    local button = ellesmereBagButton
    if InCombatLockdown() then
        if button and relative ~= button then button:Hide() end
        return
    end
    if button and relative == button then
        button:Show()
        return
    end

    local width, gap = 20, 4
    if points == 1 then
        if relative and relative ~= header then return end
        relative, anchor = header, anchor or "RIGHT"
        -- Retain the original left edge so the title and the other tools keep their space.
        local oldWidth = search:GetWidth()
        if issecretvalue and issecretvalue(oldWidth) then return end
        if oldWidth <= width + gap then return end
        search:SetWidth(oldWidth - width - gap)
    elseif anchor ~= "LEFT" or not (relative and relative:GetParent() == header) then
        return
    end

    if not button then
        button = Style.ProfessionLauncher(header, nil, ns.L.BAG_BUTTON, open)
        button:SetSize(width, 20)
        ellesmereBagButton = button
    end
    button:ClearAllPoints()
    button:SetPoint("RIGHT", relative, anchor, x, y)
    search:SetPoint("RIGHT", button, "LEFT", -gap, 0)
    button:Show()
end

function Style.RegisterBagLaunchers(open)
    Style.RegisterBagButton(open)
    if InCombatLockdown() then return end
    AttachBlizzardBagButton(ContainerFrame1, open)
    AttachBlizzardBagButton(ContainerFrameCombinedBags, open)

    local bags = EUI_MainBagFrame
    if not bags or type(bags.SyncHeaderIcons) ~= "function" then return end
    if not ellesmereHooked then
        local function Attach() AttachEllesmereBagButton(bags, open) end
        -- EllesmereUI builds the header after login and can rebuild its search anchors.
        hooksecurefunc(bags, "SyncHeaderIcons", Attach)
        bags:HookScript("OnShow", Attach)
        ellesmereHooked = true
    end
    AttachEllesmereBagButton(bags, open)
end
