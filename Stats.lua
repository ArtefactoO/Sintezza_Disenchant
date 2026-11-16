-- Stats.lua (1.8.0-dev3)
-- Session and all-time statistics of your disenchants.
--
-- Fed by Learning.lua on cast success and when materials are read, displayed by
-- the statistics window of the main file (BuildLines -> plain text lines).
--
-- What is measured, and how honestly:
--   * counts and material amounts are exact (read from the loot window).
--   * "value" = market value of the materials AT THE TIME of the disenchant,
--     from TSM/Auctionator. It is an estimate, not earned gold. A disenchant
--     whose materials are not ALL priced is counted but not valued - a missing
--     price is never treated as 0.
--   * "vs selling" compares material value with the market value of the
--     destroyed item, both after the AH cut, and only over disenchants where
--     both prices were known.
--   * "prediction vs reality" compares the expected value computed BEFORE the
--     cast (from earlier data only) with what actually dropped.
-- All-time counts and material totals are backfilled from the learned data;
-- values can only be tracked from the first run of this version on.

local _, ns = ...
ns.L = ns.L or {}
local L = ns.L

local Stats = {}
ns.Stats = Stats
local function Ignored(id)
    return ns.Learn and ns.Learn.IsIgnoredMaterial and ns.Learn.IsIgnoredMaterial(id)
end

local MAX_MATERIAL_LINES = 12
local MAX_MATERIALS, MAX_INTEGER = 512, 9007199254740991
Stats.MAX_MATERIALS=MAX_MATERIALS
local materialCounts=setmetatable({}, {__mode="k"})
local function CountMaterials(t)
    if materialCounts[t]==nil then
        local count=0;for _ in pairs(t.mats) do count=count+1 end
        materialCounts[t]=count
    end
    return materialCounts[t]
end
local function CanAdd(t,got)
    local new=0
    for id,qty in pairs(got) do
        if type(id)~="number" or id<=0 or id>MAX_INTEGER or id~=math.floor(id)
            or type(qty)~="number" or qty<=0 or qty~=math.floor(qty) or qty>MAX_INTEGER then return false end
        if t.mats[id]==nil then new=new+1
        elseif type(t.mats[id])~="number" or t.mats[id]+qty>MAX_INTEGER then return false end
    end
    return new==0 or CountMaterials(t)+new<=MAX_MATERIALS
end

local root          -- db.stats
local session       -- { startedAt, totals }
local allEpoch, sessionEpoch

local function Now()
    return (time and time()) or 0
end

local function NewTotals()
    return {
        de = 0,            -- successful casts through the addon
        mats = {},         -- itemID -> total quantity
        valued = 0,        -- disenchants whose materials were all priced
        matValue = 0,      -- copper, summed over the valued disenchants
        expN = 0,          -- disenchants with a prediction AND a value
        expSum = 0,        -- copper: expected value over those
        expActual = 0,     -- copper: actual value over those
        netN = 0,          -- disenchants with material AND item price
        net = 0,           -- copper: (materials - item) * (1 - AH cut)
    }
end

local NUMERIC_FIELDS = { "de", "valued", "matValue", "expN", "expSum", "expActual", "netN", "net" }

local function RepairTotals(t)
    if type(t) ~= "table" then t = NewTotals() end
    for _, key in ipairs(NUMERIC_FIELDS) do
        if type(t[key]) ~= "number" then t[key] = 0 end
    end
    if type(t.mats) ~= "table" then t.mats = {} end
    return t
end

-- ---------------------------------------------------------------------------
-- Init / reset
-- ---------------------------------------------------------------------------
function Stats.Init(dbRoot)
    root, session = nil, nil
    allEpoch, sessionEpoch = {}, {}
    Stats.limitReached=false;Stats.capacitySkipped=0
    materialCounts=setmetatable({}, {__mode="k"})
    Stats.storageBlocked = false
    if type(dbRoot) ~= "table" then return false end
    local needsBackfill = dbRoot.stats == nil or type(dbRoot.stats) ~= "table"
        or type(dbRoot.stats.all) ~= "table"
    local s = ns.SavedData.Prepare(dbRoot, "stats", function(data)
        if type(data.all) ~= "table" or type(data.all.mats) ~= "table"
            or type(data.valueSince) ~= "number" then return false end
        for _, key in ipairs(NUMERIC_FIELDS) do
            if type(data.all[key]) ~= "number" then return false end
        end
        return true
    end, function() return { v = 1, valueSince = Now(), all = NewTotals() } end)
    if not s then
        Stats.storageBlocked = true
        return false
    end
    if needsBackfill then
        s.all = NewTotals()
        -- Backfill counts and material amounts from the learned data.
        local learn = dbRoot.learn
        if not (ns.Learn and ns.Learn.storageBlocked)
            and type(learn) == "table" and type(learn.buckets) == "table" then
            for _, b in pairs(learn.buckets) do
                if type(b) == "table" and type(b.m) == "table" then
                    s.all.de = s.all.de + (tonumber(b.n) or 0)
                    for id, m in pairs(b.m) do
                        if not Ignored(id) then
                            if type(m)=="table" and type(m.qtySum)=="number" then
                                s.all.mats[id]=(s.all.mats[id] or 0)+m.qtySum
                            elseif type(m) == "table" and type(m.q) == "table" then
                                for qty, cnt in pairs(m.q) do
                                    s.all.mats[id] = (s.all.mats[id] or 0) + qty * cnt
                                end
                            end
                        end
                    end
                end
            end
        end
        dbRoot.stats = s
    end
    s.all = RepairTotals(s.all)
    if type(s.valueSince) ~= "number" then s.valueSince = Now() end
    root = s
    session = { startedAt = Now(), totals = NewTotals() }
    return true
end

function Stats.IsReady()
    return root ~= nil and session ~= nil
end

function Stats.ResetSession()
    if not root then return false end
    session = { startedAt = Now(), totals = NewTotals() }
    sessionEpoch = {}
    if Stats.onChange then pcall(Stats.onChange) end
    return true
end
function Stats.GetStorageUsage()
    return {all=root and CountMaterials(root.all) or 0,
        session=session and CountMaterials(session.totals) or 0,skipped=Stats.capacitySkipped or 0}
end

-- Clears the all-time numbers only; the learned disenchant data is untouched.
function Stats.ResetAll()
    if not root then return false end
    root.all = NewTotals()
    root.valueSince = Now()
    allEpoch = {}
    if Stats.onChange then pcall(Stats.onChange) end
    return true
end

local CSV_FIELDS = {
    { "queued_casts", "de", "count" }, { "manual_casts", "manual", "count" },
    { "valued_casts", "valued", "count" }, { "materials_value_copper", "matValue", "money" },
    { "comparable_casts", "netN", "count" }, { "net_vs_sale_copper", "net", "signed" },
    { "predicted_casts", "expN", "count" }, { "expected_copper", "expSum", "money" },
    { "actual_copper", "expActual", "money" },
}

local function NumberFromCSV(raw, kind)
    if type(raw) ~= "string" or not raw:match("^[%d.eE+%-]+$") then return end
    local value = tonumber(raw)
    if not value or value ~= value or math.abs(value) > MAX_INTEGER then return end
    if value < 0 and kind ~= "signed" then return end
    if kind == "count" and value % 1 ~= 0 then return end
    return value
end

local function NumberToCSV(value, kind)
    if type(value) ~= "number" or value ~= value or math.abs(value) > MAX_INTEGER then return end
    if value < 0 and kind ~= "signed" then return end
    if kind == "count" and value % 1 ~= 0 then return end
    return (kind == "count" and "%.0f" or "%.17g"):format(value)
end

local function CSVMeta(scope)
    return scope == "all" and "valuations_since" or "elapsed_seconds"
end

local function ScopedTotals(scope)
    if scope == "all" then return root.all, root.valueSince end
    return session.totals, math.max(0, Now() - session.startedAt)
end

function Stats.ExportRows(scope)
    if not (root and session) then return nil, L["STORAGE_BLOCKED"] end
    if scope ~= "all" and scope ~= "session" then return nil, L["STATS_CSV_INVALID"] end
    local totals, dateOrDuration = ScopedTotals(scope)
    local invalid = L["STATS_CSV_INVALID"]
    local meta = NumberToCSV(dateOrDuration, "count")
    if not meta then return nil, invalid end
    local rows = { { scope, CSVMeta(scope), "", meta } }
    for _, field in ipairs(CSV_FIELDS) do
        local value = NumberToCSV(totals[field[2]] or 0, field[3])
        if not value then return nil, invalid end
        rows[#rows + 1] = { scope, field[1], "", value }
    end
    local ids = {}
    for id in pairs(totals.mats) do
        if not NumberToCSV(id, "count") or id < 1 then return nil, invalid end
        ids[#ids + 1] = id
    end
    if #ids > MAX_MATERIALS then return nil, invalid end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local value = NumberToCSV(totals.mats[id], "count")
        if not value or totals.mats[id] < 1 then return nil, invalid end
        rows[#rows + 1] = { scope, "material", ("%.0f"):format(id), value }
    end
    return rows
end

function Stats.StageImport(rows)
    local invalid = L["STATS_CSV_INVALID"]
    if not (root and session) then return nil, L["STORAGE_BLOCKED"] end
    if type(rows) ~= "table" or type(rows[1]) ~= "table" then return nil, invalid end
    local scope = rows[1][1]
    if scope ~= "all" and scope ~= "session" then return nil, invalid end
    if #rows < #CSV_FIELDS + 1 or #rows > #CSV_FIELDS + 1 + MAX_MATERIALS then return nil, invalid end

    local fields, seen = {}, {}
    for _, field in ipairs(CSV_FIELDS) do fields[field[1]] = field end
    local totals, meta = NewTotals()
    for _, row in ipairs(rows) do
        if type(row) ~= "table" or #row ~= 4 then return nil, invalid end
        local rowScope, metric, item, raw = unpack(row)
        if rowScope ~= scope or type(metric) ~= "string" then return nil, invalid end
        if metric == "material" then
            local id, count = NumberFromCSV(item, "count"), NumberFromCSV(raw, "count")
            if not id or id < 1 or not count or count < 1 or totals.mats[id] then return nil, invalid end
            totals.mats[id] = count
        elseif item ~= "" or seen[metric] then
            return nil, invalid
        elseif metric == CSVMeta(scope) then
            meta = NumberFromCSV(raw, "count")
            if not meta or (scope == "session" and meta > Now()) then return nil, invalid end
            seen[metric] = true
        else
            local field = fields[metric]
            if not field then return nil, invalid end
            local value = NumberFromCSV(raw, field[3])
            if value == nil then return nil, invalid end
            totals[field[2]], seen[metric] = value, true
        end
    end
    if meta == nil then return nil, invalid end
    for _, field in ipairs(CSV_FIELDS) do if not seen[field[1]] then return nil, invalid end end
    if totals.valued > totals.de or totals.expN > totals.valued or totals.netN > totals.valued
        or (totals.valued == 0 and totals.matValue ~= 0)
        or (totals.expN == 0 and (totals.expSum ~= 0 or totals.expActual ~= 0))
        or (totals.netN == 0 and totals.net ~= 0) then return nil, invalid end

    local current, currentMeta = ScopedTotals(scope)
    local equal = (scope ~= "all" or currentMeta == meta) and CountMaterials(current) == CountMaterials(totals)
    for _, field in ipairs(CSV_FIELDS) do
        if (current[field[2]] or 0) ~= totals[field[2]] then equal = false; break end
    end
    for id, count in pairs(totals.mats) do if current.mats[id] ~= count then equal = false; break end end
    if equal then return { added = 0, duplicates = #rows } end
    return { scope = scope, totals = totals, meta = meta, replace = true, added = #rows, duplicates = 0,
        message = L[scope == "all" and "STATS_CSV_REPLACE_ALL" or "STATS_CSV_REPLACE_SESSION"] }
end

function Stats.ApplyImport(plan)
    if not (root and session) then return nil, L["STORAGE_BLOCKED"] end
    if not plan or not plan.replace then return nil, L["STATS_CSV_INVALID"] end
    if plan.scope == "all" then
        root.all, root.valueSince = plan.totals, plan.meta
        allEpoch = {}
    else
        session = { startedAt = Now() - plan.meta, totals = plan.totals }
        sessionEpoch = {}
    end
    if Stats.onChange then pcall(Stats.onChange) end
    return true
end

function Stats.Counts(scope)
    if not (root and session) then return end
    local totals = ScopedTotals(scope)
    return totals.de, totals.valued, CountMaterials(totals)
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------
local function AddTo(t, got, matValue, allPriced, snap)
    for id, qty in pairs(got) do
        if t.mats[id]==nil then materialCounts[t]=CountMaterials(t)+1 end
        t.mats[id] = (t.mats[id] or 0) + qty
    end
    if not allPriced then return end
    t.valued = t.valued + 1
    t.matValue = t.matValue + matValue
    if snap.expected then
        t.expN = t.expN + 1
        t.expSum = t.expSum + snap.expected
        t.expActual = t.expActual + matValue
    end
    if snap.sellNet then
        local cut = (ns.Prediction and ns.Prediction.AH_CUT) or 0.05
        t.netN = t.netN + 1
        t.net = t.net + (matValue * (1 - cut) - snap.sellNet)
    end
end

-- snap: item snapshot from Learning (may carry .expected / .sellNet, copper)
-- got:  { itemID = quantity } from the loot window
local function ManualCount(t)
    local n=t.manual
    return type(n)=="number" and n>=0 and n<=MAX_INTEGER and n==math.floor(n) and n or 0
end

function Stats.RecordManualCast()
    if not root or not session then return end
    local current, all = ManualCount(session.totals), ManualCount(root.all)
    if current>=MAX_INTEGER or all>=MAX_INTEGER then return end
    session.totals.manual=current+1
    root.all.manual=all+1
    if Stats.onChange then pcall(Stats.onChange) end
end

function Stats.RecordQueuedCast(snap)
    if snap then snap.statsAllEpoch, snap.statsSessionEpoch = false, false end
    if not root or not session then return end
    local current, all = session.totals, root.all
    if current.de >= MAX_INTEGER or all.de >= MAX_INTEGER then return end
    current.de = current.de + 1
    all.de = all.de + 1
    if snap then snap.statsAllEpoch, snap.statsSessionEpoch = allEpoch, sessionEpoch end
    if Stats.onChange then pcall(Stats.onChange) end
end

function Stats.Record(snap, got)
    if not (root and session and type(got) == "table" and next(got)) then return end
    if ns.Learn and ns.Learn.FilterMaterials then got=ns.Learn.FilterMaterials(got) end
    if not next(got) then return false end
    local all, current = root.all, session.totals
    if snap and snap.statsAllEpoch ~= nil then
        if snap.statsAllEpoch ~= allEpoch then all = nil end
        if snap.statsSessionEpoch ~= sessionEpoch then current = nil end
        if not all and not current then return false end
    end
    -- Reject a whole result if either view is full; never count a partial drop
    -- as complete or silently prune existing material totals.
    if (all and not CanAdd(all, got)) or (current and not CanAdd(current, got)) then
        Stats.capacitySkipped=(Stats.capacitySkipped or 0)+1
        if not Stats.limitReached and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("Sintezza Disenchant: "..L["STATS_STORAGE_LIMIT"])
        end
        Stats.limitReached=true
        return false
    end
    snap = snap or {}
    local matValue, allPriced = 0, true
    for id, qty in pairs(got) do
        local price = ns.Prediction and ns.Prediction.MaterialPrice and ns.Prediction.MaterialPrice(id)
        if type(price) == "number" then
            matValue = matValue + price * qty
        else
            allPriced = false
        end
    end
    if current then AddTo(current, got, matValue, allPriced, snap) end
    if all then AddTo(all, got, matValue, allPriced, snap) end
    if Stats.onChange then pcall(Stats.onChange) end
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
local function Money(copper)
    if ns.Prediction and ns.Prediction.Money then return ns.Prediction.Money(copper) end
    return tostring(math.floor((copper or 0) + 0.5)) .. " c"
end

local function Duration(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%dh %dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

local function DateText(t)
    return (date and date("%Y-%m-%d", t)) or tostring(t)
end

local function MaterialLines(mats, lines)
    local ids = {}
    for id in pairs(mats) do ids[#ids + 1] = id end
    for i=#ids,1,-1 do if Ignored(ids[i]) then table.remove(ids,i) end end
    if #ids == 0 then
        lines[#lines + 1] = L["STATS_MATS_NONE"]
        return
    end
    table.sort(ids, function(a, b)
        if mats[a] ~= mats[b] then return mats[a] > mats[b] end
        return a < b
    end)
    lines[#lines + 1] = L["STATS_MATS"]
    for i = 1, math.min(MAX_MATERIAL_LINES, #ids) do
        local name = (ns.Learn and ns.Learn.MaterialName and ns.Learn.MaterialName(ids[i])) or ("#" .. ids[i])
        if ns.Prediction and ns.Prediction.MaterialIcon then
            name=ns.Prediction.MaterialIcon(ids[i]).." "..name
        end
        lines[#lines + 1] = string.format(L["STATS_MAT_LINE"], name, mats[ids[i]])
    end
    if #ids > MAX_MATERIAL_LINES then
        lines[#lines + 1] = string.format(L["STATS_MATS_MORE"], #ids - MAX_MATERIAL_LINES)
    end
end

-- view = "session" | "all"; returns a list of plain text lines.
function Stats.BuildLines(view)
    local lines = {}
    if not (root and session) then
        lines[1] = L[Stats.storageBlocked and "STORAGE_BLOCKED" or "STATS_NOT_READY"]
        return lines
    end
    if Stats.limitReached then lines[#lines+1]=L["STATS_STORAGE_LIMIT"] end
    local isSession = (view ~= "all")
    local t = isSession and session.totals or root.all
    local cutPct = math.floor(((ns.Prediction and ns.Prediction.AH_CUT) or 0.05) * 100 + 0.5)

    if isSession then
        lines[#lines + 1] = string.format(L["STATS_HEAD_SESSION"],
            Duration(Now() - session.startedAt))
    else
        lines[#lines + 1] = string.format(L["STATS_HEAD_ALL"], DateText(root.valueSince))
    end
    -- Historical financial aggregates lack per-cast prices: do not fabricate a
    -- retrospective correction or reset unrelated user statistics.
    for id in pairs(t.mats) do
        if Ignored(id) then lines[#lines+1]=L["STATS_KNOWLEDGE_HISTORY"];break end
    end
    lines[#lines + 1] = " "

    if t.valued < t.de then
        lines[#lines + 1] = string.format(L["STATS_COUNT_VALUED"], t.de, t.valued)
    else
        lines[#lines + 1] = string.format(L["STATS_COUNT"], t.de)
    end
    lines[#lines + 1] = string.format(L["STATS_MANUAL_COUNT"], ManualCount(t))

    if t.valued > 0 then
        lines[#lines + 1] = string.format(L["STATS_VALUE"], Money(t.matValue))
        lines[#lines + 1] = string.format(L["STATS_VALUE_AVG"], Money(t.matValue / t.valued))
    else
        lines[#lines + 1] = L["STATS_NO_VALUE"]
    end

    if isSession and t.valued > 0 then
        local hours = (Now() - session.startedAt) / 3600
        if hours >= (1 / 60) then
            lines[#lines + 1] = string.format(L["STATS_PER_HOUR"], t.de / hours, Money(t.matValue / hours))
        end
    end

    if t.netN > 0 then
        if t.net >= 0 then
            lines[#lines + 1] = string.format(L["STATS_NET_GOOD"], cutPct, Money(t.net), t.netN)
        else
            lines[#lines + 1] = string.format(L["STATS_NET_BAD"], cutPct, Money(-t.net), t.netN)
        end
    else
        lines[#lines + 1] = L["STATS_NET_NONE"]
    end

    if t.expN > 0 then
        local ratio = (t.expSum > 0) and math.floor(t.expActual / t.expSum * 100 + 0.5) or 0
        lines[#lines + 1] = string.format(L["STATS_PRED"], Money(t.expSum), Money(t.expActual), t.expN, ratio)
    else
        lines[#lines + 1] = L["STATS_PRED_NONE"]
    end

    lines[#lines + 1] = " "
    MaterialLines(t.mats, lines)
    return lines
end
