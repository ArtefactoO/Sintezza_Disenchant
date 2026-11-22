local addon, ns = ...
ns.Icon = "Interface\\AddOns\\" .. addon .. "\\Media\\Icon"
local shared = Sintezza_Theme
ns.InterfaceFonts = shared.Fonts
ns.SettingsTheme = shared:ForAddon(function() return Sintezza_DisenchantDB end)
ns.Theme = shared.Theme
