local _, ns = ...
local Launcher = {}
ns.Launcher = Launcher

function Launcher:RegisterSettings(title, open)
    local shared = Sintezza_Theme
    if self.category or not shared.RegisterLauncherPage then return end
    self.category = shared:RegisterLauncherPage({
        title = title,
        icon = ns.Icon,
        buttonLabel = ns.L.LAUNCHER_OPEN,
        open = open,
        appearance = ns.SettingsTheme or ns.Theme,
    })
end

function Launcher:RefreshMinimap(db)
    if self.icon then self.icon:Refresh(db) end
end
