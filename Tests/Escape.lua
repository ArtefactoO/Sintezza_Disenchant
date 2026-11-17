local assertions = 0
local function check(condition, description)
    assertions = assertions + 1
    assert(condition, description)
end

local names = {
    "Sintezza_Disenchant_CheckFrame", "Sintezza_Disenchant_SettingsFrame",
    "Sintezza_Disenchant_BlacklistFrame", "Sintezza_Disenchant_MailFrame",
    "Sintezza_Disenchant_CompactFrame", "Sintezza_Disenchant_MainFrame",
}
local function frame(env)
    local result = {shown = false, hides = 0}
    function result:IsShown() return self.shown end
    function result:Hide()
        assert(not env.combat, "a window was hidden in combat")
        self.shown = false
        self.hides = self.hides + 1
    end
    return result
end
local env = NewEscapeEnvironment()
env.InCombatLockdown = function() return env.combat end
env.UISpecialFrames = {"OtherAddon", names[6]}
env.GameMenuEscPriority = {AddOn = 8}
local directRegistrations = 0
env.RegisterGameMenuEscHandler = function()
    directRegistrations = directRegistrations + 1
end
env.ns.RegisterEscapeHandling()
check(directRegistrations == 0, "do not register in the protected Escape dispatcher")
check(env.UISpecialFrames[1] == "OtherAddon" and #env.UISpecialFrames == 7, "register special windows")
env.ns.UpdateEscapeWindows()
check(#env.UISpecialFrames == 7, "repeated registration has no duplicates")
for _, name in ipairs(names) do env[name] = frame(env) end

local function CloseSpecialWindows()
    local closed = false
    for _, name in ipairs(env.UISpecialFrames) do
        local window = env[name]
        if window and window:IsShown() then
            window:Hide()
            closed = true
        end
    end
    return closed
end

check(not CloseSpecialWindows(), "leave Escape to the game when no window is shown")
for _, name in ipairs(names) do
    env[name].shown = true
    check(CloseSpecialWindows() and not env[name].shown, "close " .. name)
    check(env[name].hides == 1, "close only once: " .. name)
end

env[names[5]].shown = true
env.combat = true
env.ns.UpdateEscapeWindows()
check(#env.UISpecialFrames == 1 and env.UISpecialFrames[1] == "OtherAddon", "remove our windows in combat")
check(not CloseSpecialWindows() and env[names[5]].shown, "leave combat Escape to the game")
env.combat = false
env.ns.UpdateEscapeWindows()
check(CloseSpecialWindows() and not env[names[5]].shown, "close compact window after combat")

env[names[6]].shown = true
env.ns.ProfessionViews.page = {}
env.ns.UpdateEscapeWindows()
check(#env.UISpecialFrames == 1 and env.UISpecialFrames[1] == "OtherAddon", "defer to Blizzard on the embedded page")
check(not CloseSpecialWindows() and env[names[6]].shown, "leave embedded window to Blizzard")
env.combat = true
env.ns.UpdateEscapeWindows()
env.combat = false
env.ns.UpdateEscapeWindows()
check(not CloseSpecialWindows(), "combat ending does not register the embedded page")
env.ns.ProfessionViews.page = nil
env.ns.UpdateEscapeWindows()
check(CloseSpecialWindows() and not env[names[6]].shown, "close standalone main window again")
return assertions
