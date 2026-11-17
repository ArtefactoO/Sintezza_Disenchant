"""Offline checks for Disenchant selection, window lifecycle and dynamic lists."""

from argparse import ArgumentParser
import json
from pathlib import Path
import re
import sys


ADDON = Path(__file__).resolve().parents[1]


def queue_policy(source, lua):
    start = source.index("local function IsSetProtected(item)")
    end = source.index("\nlocal itemLoadRefreshQueued", start)
    code = source[start:end]
    for name in ("IsSetProtected", "IsIlvlProtected", "PriceProtectionThreshold", "IsValuableItem"):
        declaration = re.search(rf"local function {name}\([^)]*\)\n", code)[0]
        code = code.replace(declaration, declaration + f"    checks.{name} = checks.{name} + 1\n", 1)
    wrapper = """
return function(input)
    local db, activeMode = input.db, input.mode
    local items, selected = input.items, input.selected or {}
    local queue, valuableSkippedCount = {}, 0
    local ns = {}
    local compactFrame
    if input.frameShown ~= nil then
        compactFrame = { IsShown = function() return input.frameShown end }
    end
    local checks = { IsSetProtected = 0, IsIlvlProtected = 0, PriceProtectionThreshold = 0, IsValuableItem = 0 }
    local function wipe(list) for key in pairs(list) do list[key] = nil end end
""" + code + """
    if input.onlyProtection then
        local decisions = {}
        for i, item in ipairs(items) do decisions[i] = IsAutoQueueProtected(item) end
        return { decisions = decisions, checks = checks }
    end
    BuildQueue()
    if input.rebuildSelected then
        selected = input.rebuildSelected
        BuildQueue()
    end
    return { queue = queue, skipped = ns.GetValuableSkippedCount(), checks = checks }
end
"""
    return lua.execute(wrapper)


def escape_environment(source, lua):
    start = source.index("function ns.RegisterEscapeHandling()")
    end = source.index('\naddon:SetScript("OnEvent"', start)
    code = source[start:end]
    make = lua.eval('''function(code)
        return function()
            local env = setmetatable({}, {__index = _G})
            env._G = env
            env.ns = {ProfessionViews = {}}
            local chunk = assert(loadstring(code, "@EscapeHandling"))
            setfenv(chunk, env)
            chunk()
            return env
        end
    end''')
    return make(code)


def list_environment(source, lua):
    start = source.index("local function CreateIconBorder(")
    icons = source[start:source.index("local function EnsureDB()", start)]
    start = source.index("local function PreviewForItem(")
    rows = source[start:source.index("\nlocal function ClassifyDisenchantFailure(", start)]
    start = source.index("local function UpdateLayout()")
    end = source.index("\nlocal function DockQueueButtonToCompact()", start)
    refresh = source[start:end]
    start = source.index("    local clearButton = ns.Style.Button(controlsFrame)")
    end = source.index("\n    statusText =", start)
    select = source[start:end]
    start = source.index("    function mainContent:AnchorMainTitle()")
    title_start = source.rfind("    local titlePoint =", 0, start)
    if title_start != -1:
        start = title_start
    header = source[start:source.index("\n    statsButton:SetSize", start)]
    diagnostics = ""
    if "local function DescribeViewport(" in source:
        start = source.index("local function DescribeViewport(")
        diagnostics = source[start:source.index("\nlocal function RunSelfCheck(", start)]
        diagnostics += "\nDescribeTestViewport = DescribeViewport\n"
    if "local function CreateRowsViewport(" in source:
        views = '''
listScrollFrame = CreateRowsViewport(listPanel)
queueScrollFrame = CreateRowsViewport(queuePanel)
'''
    else:
        views = '''
listScrollFrame = CreateFrame("ScrollFrame", nil, listPanel)
queueScrollFrame = CreateFrame("ScrollFrame", nil, queuePanel)
listScrollChild = CreateFrame("Frame", nil, listScrollFrame)
queueScrollChild = CreateFrame("Frame", nil, queueScrollFrame)
listScrollFrame:SetScrollChild(listScrollChild)
queueScrollFrame:SetScrollChild(queueScrollChild)
listScrollFrame:HookScript("OnSizeChanged", RequestListRowsUpdate)
listScrollFrame:HookScript("OnShow", RequestListRowsUpdate)
queueScrollFrame:HookScript("OnSizeChanged", UpdateQueueRows)
'''
    make = lua.eval('''function(code)
        return function(env)
            setmetatable(env, {__index = _G})
            local chunk = assert(loadstring(code, "@ListRefresh"))
            setfenv(chunk, env)
            chunk()
        end
    end''')
    return make(icons + "\n" + rows + "\n" + refresh + "\n" + select + "\n" + views + "\n" + header + "\n" + diagnostics
                + "\nmainFrame.RefreshUI = RefreshUI\n")


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, help="Directory containing a compatible Lupa installation")
    parser.add_argument("--baseline", type=Path, help="Optional pre-change Sintezza_Disenchant.lua for differential checks")
    parser.add_argument("--list-source", type=Path, help="Source snapshot to run the list regression against")
    args = parser.parse_args()
    if args.runtime:
        sys.path.insert(0, str(args.runtime.resolve()))
    import lupa
    from lupa.lua51 import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=True)
    compile_lua = lua.eval("function(source, name) local chunk, err = loadstring(source, name); assert(chunk, err) end")
    sources = sorted(ADDON.rglob("*.lua"))
    for path in sources:
        if any(part.startswith(".") for part in path.relative_to(ADDON).parts):
            continue
        compile_lua(path.read_text(encoding="utf-8-sig"), "@" + str(path))
    source = (ADDON / "Sintezza_Disenchant.lua").read_text(encoding="utf-8-sig")
    lua.globals().QueueRun = queue_policy(source, lua)
    lua.globals().NewEscapeEnvironment = escape_environment(source, lua)
    list_source = args.list_source.read_text(encoding="utf-8-sig") if args.list_source else source
    lua.globals().LoadListEnvironment = list_environment(list_source, lua)
    if args.baseline:
        baseline = args.baseline.read_text(encoding="utf-8-sig")
        lua.globals().QueueBaseline = queue_policy(baseline, lua)
    result = lua.execute((ADDON / "Tests/QueuePolicy.lua").read_text(encoding="utf-8"))
    escape = lua.execute((ADDON / "Tests/Escape.lua").read_text(encoding="utf-8"))
    viewport = lua.execute((ADDON / "Tests/ListRefresh.lua").read_text(encoding="utf-8"))
    assert 'ns.RegisterEscapeHandling()\n        windowAppearance:Bind(settingsFrame' in source
    assert 'addon:RegisterEvent("PLAYER_REGEN_DISABLED")' in source
    assert source.count('if ns.UpdateEscapeWindows then ns.UpdateEscapeWindows() end') == 3
    values = dict(result.items())
    print(f"Lua 5.1 syntax, Lupa {lupa.__version__}: PASS")
    print(json.dumps(values, sort_keys=True))
    print(f"Escape handling: {escape} assertions passed")
    print(f"List refresh: {viewport} assertions passed")


if __name__ == "__main__":
    main()
