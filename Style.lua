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
    api.RegisterRegion("Sintezza Disenchant", addonName, "backpack", "top_left", button)
    bagButton = button
    -- Baganator installs its active skinner during PLAYER_LOGIN.
    C_Timer.After(0, function()
        local skins = Baganator.Skins
        if skins and skins.AddFrame then skins.AddFrame("IconButton", button, {}) end
        if api.RequestLayoutUpdate then api.RequestLayoutUpdate() end
    end)
end
