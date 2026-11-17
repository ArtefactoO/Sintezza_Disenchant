local assertions, comparisons = 0, 0

local function Check(condition, message)
    assertions = assertions + 1
    assert(condition, message)
end

local function Item(key, values)
    local item = { key = key, itemLevel = 40 }
    for field, value in pairs(values or {}) do item[field] = value end
    return item
end

local function Settings(values)
    local db = { compactMode = true, priceWarnEnabled = true, priceThresholdGold = 5,
        protectSets = true, ilvlCapEnabled = true, ilvlCap = 100, skipUnknownPrice = false }
    for field, value in pairs(values or {}) do db[field] = value end
    return db
end

local protectedMode = { key = "disenchant", usesItemProtection = true }
local function Run(items, selected, db, frameShown, mode)
    return QueueRun({ items = items, selected = selected, db = db or Settings(),
        frameShown = frameShown, mode = mode or protectedMode })
end

local function Keys(result)
    local keys = {}
    for i, item in ipairs(result.queue) do keys[i] = item.key end
    return table.concat(keys, ",")
end

local items = {
    Item("valuable", { priceCopper = 60000 }),
    Item("set", { isSet = true, priceCopper = 60000 }),
    Item("manual", { manualOnly = true }),
    Item("level", { itemLevel = 100 }),
    Item("blocked", { disenchantBlocked = true }),
    Item("excluded", { excluded = true }),
    Item("cheap", { priceCopper = 49000 }),
    Item("unknown"),
}
local selected = {}
for _, item in ipairs(items) do selected[item.key] = true end
local result = Run(items, selected, nil, true)
Check(Keys(result) == "valuable,set,manual,level,cheap,unknown", "manual selection bypasses only automatic protections")
Check(result.skipped == 0, "manual selection has no automatic price-skip count")
for i, queued in ipairs(result.queue) do
    Check(queued == items[i <= 4 and i or i + 2], "queue retains the scanned item object")
end

result = Run(items, {}, nil, true)
Check(Keys(result) == "cheap,unknown", "compact fallback applies every automatic protection")
Check(result.skipped == 1, "only the solely valuable item counts as price-skipped")
Check(Keys(Run(items, {}, nil, false)) == "", "hidden compact frame does not fill the queue")
Check(Keys(Run(items, {}, Settings({ compactMode = false }), true)) == "", "full mode does not auto-fill")
Check(Keys(Run(items, {}, nil, nil)) == "", "absent compact frame does not auto-fill")
Check(Keys(Run(items, { blocked = true, excluded = true }, nil, true)) == "cheap,unknown",
    "invalid selections still permit compact fallback")
Check(Keys(Run(items, { cheap = true, unknown = false }, nil, true)) == "cheap",
    "a valid manual selection suppresses compact fallback")

local boundary = { Item("below", { priceCopper = 49999 }), Item("equal", { priceCopper = 50000 }),
    Item("above", { priceCopper = 50001 }), Item("unknown") }
result = Run(boundary, {}, Settings({ skipUnknownPrice = true }), true)
Check(Keys(result) == "below", "price equality is protected and an active unknown-price guard skips missing prices")
Check(result.skipped == 2, "missing prices do not count as valuable")
result = Run(boundary, {}, Settings({ priceWarnEnabled = false, skipUnknownPrice = true }), true)
Check(Keys(result) == "below,equal,above,unknown", "disabled price guard does not reject missing prices")
Check(result.skipped == 0, "disabled price guard leaves price-skip count empty")

local nonEquipment = { key = "milling", usesItemProtection = false }
result = Run(items, {}, nil, true, nonEquipment)
Check(Keys(result) == "valuable,set,manual,level,cheap,unknown", "other modes ignore equipment and price protections")
Check(result.skipped == 0 and result.checks.PriceProtectionThreshold == 0, "other modes do no price-policy work")

local unusual = { Item("plain", { priceCopper = 1, itemLevel = 40 }) }
for _, invalid in ipairs({ -1, math.huge, -math.huge, 0/0, "bad", false }) do
    result = Run(unusual, {}, Settings({ ilvlCap = invalid, priceThresholdGold = invalid }), true)
    Check(Keys(result) == "plain", "invalid saved thresholds do not add an automatic protection")
end
result = Run(unusual, {}, Settings({ ilvlCap = "40", priceThresholdGold = "5" }), true)
Check(Keys(result) == "", "numeric strings in older profiles retain threshold behavior")
result = QueueRun({ items = unusual, selected = {}, frameShown = true })
Check(Keys(result) == "", "uninitialized settings cannot auto-fill")

local resetItems = { Item("price", { priceCopper = 50000 }), Item("normal", { priceCopper = 1 }) }
result = QueueRun({ items = resetItems, selected = {}, db = Settings(), mode = protectedMode,
    frameShown = true, rebuildSelected = { normal = true } })
Check(Keys(result) == "normal" and result.skipped == 0, "a subsequent manual build resets the price-skip count")

local benchmarkItems = {}
for i = 1, 200 do benchmarkItems[i] = Item(tostring(i), { priceCopper = 60000 }) end
local benchmarkInput = { items = benchmarkItems, selected = {}, db = Settings(), mode = protectedMode, frameShown = true }
local after = QueueRun(benchmarkInput)
Check(#after.queue == 0 and after.skipped == 200, "large automatic queues retain exact skip totals")

local baselineChecks
if QueueBaseline then
    local before = QueueBaseline(benchmarkInput)
    baselineChecks = before.checks.PriceProtectionThreshold
    Check(before.checks.PriceProtectionThreshold == 400 and after.checks.PriceProtectionThreshold == 200,
        "price protection is evaluated once instead of twice per valuable item")
    Check(before.checks.IsSetProtected == 400 and after.checks.IsSetProtected == 200,
        "set protection is evaluated once per item")
    Check(before.checks.IsIlvlProtected == 400 and after.checks.IsIlvlProtected == 200,
        "item-level protection is evaluated once per item")

    local function Compare(input)
        local oldOK, old = pcall(QueueBaseline, input)
        local newOK, new = pcall(QueueRun, input)
        comparisons = comparisons + 1
        assert(oldOK == newOK, "changed handling of corrupt settings")
        if not oldOK then return end
        if input.onlyProtection then
            for i = 1, #input.items do
                assert(old.decisions[i] == new.decisions[i], "automatic selection policy differs")
            end
        else
            assert(old.skipped == new.skipped, "price-skip count differs")
            assert(#old.queue == #new.queue, "queue length differs")
            for i, item in ipairs(old.queue) do assert(item == new.queue[i], "queue order or identity differs") end
        end
    end

    local olderProfiles = {
        { compactMode = true },
        { compactMode = true, priceWarnEnabled = true },
        { compactMode = true, ilvlCapEnabled = true },
        { compactMode = true, protectSets = "old-enabled-value" },
        { compactMode = true, priceWarnEnabled = true, priceThresholdGold = {}, skipUnknownPrice = true },
        { compactMode = true, ilvlCapEnabled = true, ilvlCap = {} },
    }
    for _, db in ipairs(olderProfiles) do
        Compare({ items = items, selected = {}, db = db, mode = protectedMode, frameShown = true })
        Compare({ items = items, selected = selected, db = db, mode = protectedMode, frameShown = true })
        Compare({ items = items, db = db, mode = protectedMode, onlyProtection = true })
    end

    local thresholds = { false, 0, 1, 5, "5", -1, math.huge, -math.huge, 0/0, "bad" }
    local caps = { false, 0, 40, 100, "40", -1, math.huge, 0/0, "bad" }
    local prices = { false, 0, 49999, 50000, 50001, 100000 }
    local modes = { false, protectedMode, nonEquipment }
    local frames = { "absent", "hidden", "shown" }
    for mask = 0, 63 do
        local function Bit(index) return math.floor(mask / 2^index) % 2 == 1 end
        for index, threshold in ipairs(thresholds) do
            for _, mode in ipairs(modes) do
                local testItems = {
                    Item("first", { priceCopper = prices[index % #prices + 1] or nil, itemLevel = 40,
                        manualOnly = Bit(0), isSet = Bit(1), excluded = Bit(2), disenchantBlocked = Bit(3) }),
                    Item("second", { priceCopper = 50000, itemLevel = 100 }),
                    Item("third", { priceCopper = nil, itemLevel = 39 }),
                }
                local db = Settings({ priceThresholdGold = threshold, ilvlCap = caps[index % #caps + 1],
                    priceWarnEnabled = Bit(4), skipUnknownPrice = Bit(5), protectSets = index % 2 == 0,
                    ilvlCapEnabled = index % 3 ~= 0 })
                for selection = 1, 4 do
                    local picked = selection == 1 and {} or selection == 2 and { first = true }
                        or selection == 3 and { first = true, second = false, third = true }
                        or { first = false, missing = true }
                    for _, frame in ipairs(frames) do
                        local shown
                        if frame ~= "absent" then shown = frame == "shown" end
                        Compare({ items = testItems, selected = picked, db = db, mode = mode or nil, frameShown = shown })
                        db.compactMode = false
                        Compare({ items = testItems, selected = picked, db = db, mode = mode or nil, frameShown = shown })
                        db.compactMode = true
                    end
                end
                Compare({ items = testItems, db = db, mode = mode or nil, onlyProtection = true })
            end
        end
    end
end

return {
    assertions = assertions,
    differential_cases = comparisons,
    price_checks_before = baselineChecks,
    price_checks_after = after.checks.PriceProtectionThreshold,
    set_checks_after = after.checks.IsSetProtected,
    level_checks_after = after.checks.IsIlvlProtected,
}
