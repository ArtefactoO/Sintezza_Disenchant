local assertions = 0
local function check(condition, message)
    assertions = assertions + 1
    assert(condition, message)
end

local function environment()
    local env = {items = {}, selected = {}, listRows = {}, queueRows = {}, queue = {}, timers = {}, estimates = 0, scans = 0, created = 0}
    env.db = {showExpected = true}
    env.activeMode = {key = "disenchant", usesItemProtection = true, isKnown = function() return true end}
    env.ROW_HEIGHT, env.ROW_SPACING, env.QUEUE_PANEL_WIDTH = 30, 4, 320
    env.L = {COMPACT_EMPTY = "Empty", WAITING_FOR_ITEMS = "Waiting %d", PICKS_COUNT = "Marked: %d", PICKS_FALLBACK = "Fallback",
        UNKNOWN = "Unknown", ITEM_LEVEL = "(ilvl %d)%s", DELETE = "Remove"}
    env.L.CHECK_VIEW_MISSING = "not created"
    env.L.CHECK_VIEW_STATE = "shown/visible %d/%d, items %d, rows %d/%d, offset/range %s/%s, pending %s, bounds %s, first %s %d/%d alpha %s revision %s/%s"
    env.InCombatLockdown = function() return env.combat end
    env.C_Timer = {After = function(_, callback) env.timers[#env.timers + 1] = callback end}
    env.wipe = function(t) for key in pairs(t) do t[key] = nil end end
    env.IsBlacklistedItem = function() return false end
    env.StripColorCodes = function(text) return text end
    env.Print = function() end
    local fractions = {TOPLEFT={0,1}, TOP={.5,1}, TOPRIGHT={1,1}, LEFT={0,.5}, CENTER={.5,.5}, RIGHT={1,.5}, BOTTOMLEFT={0,0}, BOTTOM={.5,0}, BOTTOMRIGHT={1,0}}

    local function widget(parent, kind)
        env.created = env.created + 1
        local frame = {parent = parent, kind = kind, shown = true, width = 1, height = 1, points = {}, hooks = {}, scripts = {}, text = ""}
        local function geometryChanged()
            frame.geometryWrites = (frame.geometryWrites or 0) + 1
            if env.geometryObserver then env.geometryObserver() end
        end
        function frame:GetRect()
            local xs, ys = {}, {}
            for key, point in pairs(self.points) do
                local relative, anchor, x, y = unpack(point)
                local left, bottom, width, height = relative:GetRect()
                xs[#xs + 1] = {fractions[key][1], left + fractions[anchor][1] * width + x}
                ys[#ys + 1] = {fractions[key][2], bottom + fractions[anchor][2] * height + y}
            end
            local function axis(points, size)
                if #points == 0 then return 0, size end
                for i = 2, #points do
                    if points[i][1] ~= points[1][1] then
                        size = (points[i][2] - points[1][2]) / (points[i][1] - points[1][1])
                        break
                    end
                end
                return points[1][2] - points[1][1] * size, size
            end
            local left, width = axis(xs, self.width)
            local bottom, height = axis(ys, self.height)
            return left, bottom, width, height
        end
        function frame:GetWidth() return select(3, self:GetRect()) end
        function frame:GetHeight() return select(4, self:GetRect()) end
        function frame:SetWidth(value) self.width = value; geometryChanged() end
        function frame:SetHeight(value) self.height = value; self.heightWrites = (self.heightWrites or 0) + 1; geometryChanged() end
        function frame:SetSize(width, height) self.width = width; self:SetHeight(height) end
        function frame:SetPoint(key, relative, anchor, x, y)
            if type(relative) ~= "table" then x, y, relative, anchor = relative or 0, anchor or 0, self.parent, key end
            self.points[key] = {relative or self.parent, anchor or key, x or 0, y or 0}
            geometryChanged()
        end
        function frame:ClearAllPoints() self.points = {}; geometryChanged() end
        function frame:GetPoint(index)
            for key, point in pairs(self.points) do
                index = index - 1
                if index == 0 then return key, unpack(point) end
            end
        end
        function frame:SetAllPoints(relative)
            self:SetPoint("TOPLEFT", relative or self.parent, "TOPLEFT")
            self:SetPoint("BOTTOMRIGHT", relative or self.parent, "BOTTOMRIGHT")
        end
        function frame:Run(name, ...)
            if self.scripts[name] then self.scripts[name](self, ...) end
            for _, callback in ipairs(self.hooks[name] or {}) do callback(self, ...) end
        end
        function frame:SetScript(name, callback) self.scripts[name] = callback end
        function frame:HookScript(name, callback)
            self.hooks[name] = self.hooks[name] or {}
            table.insert(self.hooks[name], callback)
        end
        function frame:SetShown(shown)
            if self.shown == shown then return end
            self.shown = shown
            self:Run(shown and "OnShow" or "OnHide")
        end
        function frame:Show() self:SetShown(true) end
        function frame:Hide() self:SetShown(false) end
        function frame:IsShown() return self.shown end
        function frame:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
        function frame:GetParent() return self.parent end
        function frame:GetFrameLevel() return 1 end
        function frame:GetAlpha() return 1 end
        function frame:CreateTexture() return widget(self, "Texture") end
        function frame:CreateFontString() return widget(self, "FontString") end
        function frame:SetText(text) self.text = text end
        function frame:GetStringWidth() return #self.text * 5 end
        function frame:SetChecked(value) self.checked = value end
        function frame:SetEnabled(value) self.enabled = value end
        function frame:EnableMouse(value) self.mouse = value end
        function frame:EnableMouseMotion(value) self.mouseMotion = value end
        function frame:SetTexture(value) self.texture = value end
        function frame:SetTextColor(...) self.color = {...} end
        function frame:SetClipsChildren(value) self.clips = value end
        function frame:SetMinMaxValues(low, high) self.low, self.high = low, high end
        function frame:SetValue(value)
            if self.value == value then return end
            self.value = value
            self:Run("OnValueChanged", value)
        end
        for _, name in ipairs({"SetOrientation", "SetValueStep", "SetObeyStepOnDrag", "EnableMouseWheel", "SetFrameLevel",
            "SetDesaturated", "SetVertexColor", "SetTexCoord", "SetAlpha", "SetJustifyH", "SetWordWrap", "RegisterForClicks"}) do
            frame[name] = function() end
        end
        -- Let the pre-change source run as a negative control.
        function frame:SetScrollChild(child) self.child = child end
        function frame:UpdateScrollChildRect() end
        function frame:GetVerticalScroll() return self.offset or 0 end
        function frame:SetVerticalScroll(value) self.offset = value end
        function frame:SetHorizontalScroll(value) self.horizontal = value end
        function frame:RefreshRange(range) self.range = range or math.max(0, self.child:GetHeight() - self:GetHeight()) end
        return frame
    end
    env.CreateFrame = function(kind, _, parent) return widget(parent, kind) end
    env.GameTooltip = {
        IsOwned = function(self, frame) return self.owner ~= nil and self.owner == frame end,
        SetOwner = function(self, frame) self.owner, self.previewItem = frame, nil end,
        SetBagItem = function(self, bag, slot) self.bag, self.slot = bag, slot end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.owner, self.shown = nil, false end,
    }
    env.mainContent = widget()
    env.mainContent:SetSize(860, 580)
    env.mainFrame = env.mainContent
    env.titleBrand = widget(env.mainContent)
    env.mainFrame.title = widget(env.mainContent)
    env.mainFrame.title:SetPoint("LEFT", env.titleBrand, "RIGHT", 10, 0)
    env.mainFrame.TitleBar = {version = widget(env.mainContent)}
    env.blacklistOpenButton = widget(env.mainContent)
    env.mainContent.compactModeButton = widget(env.mainContent)
    env.listPanel, env.queuePanel = widget(env.mainContent), widget(env.mainContent)
    env.controlsFrame = widget(env.listPanel)
    env.refreshButton = widget(env.controlsFrame)
    env.ns = {
        ProfessionViews = {SyncAction = function() end},
        Style = {Button = widget, CheckButton = widget},
        InterfaceFonts = {CreateText = function(_, parent) return widget(parent) end},
        SettingsTheme = {RowBand = function(_, parent) return widget(parent) end,
            MenuHighlight = function(_, parent) return widget(parent) end,
            FrameIcon = function(_, parent) return widget(parent) end,
            PaintItemBorder = function() end, PaintButton = function() end, SkinScrollBar = function() end},
        Prediction = {
            Estimate = function(item) env.estimates = env.estimates + 1; return item end,
            BuildPreview = function(item) return "Materials " .. item.key end,
            IsDisenchantPick = function(item, advice) return advice and advice.pick or item.pick, advice == nil end,
        },
    }
    env.ScanBags = function() env.scans = env.scans + 1 end
    env.BuildQueue = function()
        env.queue = {}
        for _, item in ipairs(env.items) do
            if env.selected[item.key] then env.queue[#env.queue + 1] = item end
        end
    end
    env.IsAutoQueueProtected = function(item) return item.excluded end
    env.UpdateStatusText = function() env.status = env.bulkMessage end
    env.UpdateQueueButton = function() end
    env.UpdateCompactFrame = function() end
    function env:Flush()
        local pending = self.timers
        self.timers = {}
        for _, callback in ipairs(pending) do callback() end
    end
    function env:Fill(count)
        self.items = {}
        for index = 1, count do
            self.items[index] = {key = tostring(index), name = "Item " .. index, pick = index % 2 == 1, itemLevel = 20, quality = 2}
        end
    end
    LoadListEnvironment(env)
    env.controlsFrame:SetPoint("BOTTOMLEFT", env.listPanel, "BOTTOMLEFT", 8, 8)
    env.controlsFrame:SetPoint("BOTTOMRIGHT", env.listPanel, "BOTTOMRIGHT", -8, 8)
    env.controlsFrame:SetHeight(24)
    env.listScrollFrame:SetPoint("TOPLEFT", env.listPanel, "TOPLEFT", 8, -8)
    env.listScrollFrame:SetPoint("BOTTOMRIGHT", env.controlsFrame, "TOPRIGHT", -22, 8)
    env.listScrollFrame.empty = widget(env.listPanel)
    env.queueScrollFrame:SetPoint("TOPLEFT", env.queuePanel, "TOPLEFT", 8, -60)
    env.queueScrollFrame:SetPoint("BOTTOMRIGHT", env.queuePanel, "BOTTOMRIGHT", -30, 46)
    function env:Resize(width, height)
        self.mainContent:SetSize(width, height)
        self.controlsFrame:SetHeight(self.listPanel:GetWidth() < 576 and 43 or 24)
        self.listScrollFrame:Run("OnSizeChanged")
        self.queueScrollFrame:Run("OnSizeChanged")
    end
    return env
end

local function visibleRows(rows)
    local count = 0
    for _, row in ipairs(rows) do if row:IsVisible() and row.item then count = count + 1 end end
    return count
end

local env = environment()
env:Fill(1000)
local resolvedHeight = env.listScrollFrame.GetHeight
env.listScrollFrame.GetHeight = function() return 0 end
env.listScrollFrame:Run("OnShow")
env.RefreshUI()
env.listScrollFrame.GetHeight = resolvedHeight
env:Flush()
check(visibleRows(env.listRows) > 0, "the pending show refresh must survive unresolved initial viewport dimensions")
check(#env.timers == 0, "the settled first draw does not leave a refresh loop")
check(#env.listRows <= 10, "large bags must allocate rows only for the visible viewport")
check(env.estimates == #env.listRows, "material estimates must be limited to visible rows")
check(env.listScrollFrame.kind == "Frame" and env.listScrollFrame.clips, "the list uses a clipped frame without a native scroll child")
check(env.listScrollFrame.range == 1000 - visibleRows(env.listRows), "scroll range reaches all items")
local first = env.listRows[1]
local function relativeGeometry(region, row)
    local x, y, _, height = region:GetRect()
    local rowX, rowY = row:GetRect()
    return x - rowX, y - rowY, height
end
local iconX, iconY, iconHeight = relativeGeometry(first.icon, first)
local previewX, previewY, previewHeight = relativeGeometry(first.preview, first)
check(previewHeight >= 18 and previewY >= 0 and previewY + previewHeight <= first:GetHeight(), "material icons have a full-height text area inside the row")
local heightWrites = first.heightWrites
local stableGeometry = true
local estimates, scans, created = env.estimates, env.scans, env.created
for size = 861, 1000 do
    env:Resize(size, 580); env:Flush()
    local x, y, height = relativeGeometry(first.icon, first)
    local px, py, ph = relativeGeometry(first.preview, first)
    stableGeometry = stableGeometry and x == iconX and y == iconY and height == iconHeight
        and px == previewX and py == previewY and ph == previewHeight
end
check(stableGeometry, "item and reagent positions and heights stay fixed across 140 width changes")
check(first.heightWrites == heightWrites, "horizontal resizing never reapplies row height")
check(env.estimates == estimates and env.scans == scans, "width-only resizing must not rescan bags or recalculate materials")
check(env.created == created and env.listRows[1] == first, "width resizing reuses existing widgets")
check(first:GetWidth() == math.floor(env.listScrollFrame:GetWidth()), "rows expand to the current viewport width")
check(#env.timers == 0, "resize refreshes stop when resizing stops")
env:Resize(1000, 960)
env:Flush()
check(visibleRows(env.listRows) > 10 and #env.listRows < 20, "taller windows display more rows without allocating the entire bag")
for _, row in ipairs(env.listRows) do
    if row:IsVisible() then
        local _, bottom, _, height = row:GetRect()
        local _, viewBottom, _, viewHeight = env.listScrollFrame:GetRect()
        check(bottom >= viewBottom and bottom + height <= viewBottom + viewHeight, "every visible row fits inside its viewport")
    end
end

env.mainContent.selectAllButton:Run("OnClick")
env:Flush()
check(#env.queue == 500 and env.selected["999"], "Mark best picks includes offscreen items")
check(visibleRows(env.listRows) > 0 and visibleRows(env.queueRows) > 0, "both lists stay visible after the queue opens")
check(#env.queueRows < 35, "queue row allocation is limited by viewport height")
check(env.status == "Marked: 500 · Fallback", "fallback selection works without optional price addons")
estimates, scans = env.estimates, env.scans
for size = 460, 960, 10 do env:Resize(860, size) end
check(#env.timers == 1, "resize events for both lists share one deferred refresh")
env:Flush()
check(env.estimates == estimates and env.scans == scans, "coalesced geometry changes do not refresh unchanged item data")
estimates, scans, created = env.estimates, env.scans, env.created
for size = 460, 960, 10 do env:Resize(860, size); env:Flush() end
check(env.estimates - estimates <= 14 and env.scans == scans, "continuous height resizing estimates only newly exposed rows")
check(env.created == created and #env.timers == 0, "continuous height resizing reuses both row pools without a timer loop")
check(visibleRows(env.listRows) > 0 and visibleRows(env.queueRows) > 0, "both lists recover from the minimum to maximum window height")

env.listScrollFrame:Run("OnMouseWheel", -1)
env:Flush()
check(first.item.key == "4" and not first.checkbox.checked, "wheel scrolling rebinds the row and checkbox to the visible item")
env.GameTooltip.owner = first
env.listScrollFrame.bar:Run("OnValueChanged", env.listScrollFrame.range)
env:Flush()
check(env.GameTooltip.owner == nil, "recycled rows dismiss their previous tooltip")
check(env.listRows[visibleRows(env.listRows)].item.key == "1000", "scrollbar reaches the final bag item")
first:Run("OnClick")
env:Flush()
check(first.checkbox.checked == (env.selected[first.item.key] == true), "clicking a recycled row selects its current item")

env.queueScrollFrame.bar:Run("OnValueChanged", env.queueScrollFrame.range)
env:Flush()
local lastQueue = env.queueRows[visibleRows(env.queueRows)]
check(lastQueue.item == env.queue[#env.queue] and lastQueue.label.text:match("^" .. #env.queue .. "%. "), "queue scrolling preserves item identity and numbering")
local removed = lastQueue.item.key
lastQueue.removeButton:Run("OnClick")
env:Flush()
check(not env.selected[removed], "removing a recycled queue row removes the correct item")

env:Fill(2)
env.selected = {}
env.BuildQueue()
env.RefreshList()
env:Flush()
check(env.listScrollFrame.offset == 0 and visibleRows(env.listRows) == 2, "shrinking bags clamp the offset and hide unused rows")
check(not env.listScrollFrame.bar:IsShown() and not env.queueScrollFrame.bar:IsVisible(), "short lists and hidden queues hide their scrollbars")
env.mainContent:Hide()
env.RefreshUI()
estimates = env.estimates
env:Flush()
check(env.estimates == estimates, "hidden lists do no item rendering work")
env.mainContent:Show()
env.listScrollFrame:Run("OnShow")
env.RefreshList()
check(#env.timers == 1, "reopening coalesces show and data changes into one settled draw")
env:Flush()
check(visibleRows(env.listRows) == 2, "reopening restores the item list")

env:Resize(900, 600)
env.combat = true
estimates = env.estimates
env:Flush()
check(env.estimates == estimates and env.needsRefreshAfterCombat, "combat blocks a scheduled row refresh")
local offset = env.listScrollFrame.offset
env.listScrollFrame:Run("OnMouseWheel", -1)
check(env.listScrollFrame.offset == offset and #env.timers == 0, "combat blocks scrolling")
env.combat = false
env.RefreshList()
env:Flush()
check(visibleRows(env.listRows) == 2, "the post-combat refresh restores the rows")
env.db.showExpected = false
env:Fill(100)
env.RefreshUI()
estimates = env.estimates
env:Flush()
check(env.listRows[1]:GetHeight() == 30 and env.estimates == estimates, "disabling previews fits shorter rows without material work")
local _, titleY, titleHeight = relativeGeometry(env.listRows[1].label, env.listRows[1])
check(titleY >= 0 and titleY + titleHeight <= 30, "the title remains inside the shorter row when previews are disabled")
env:Fill(0)
env.ns.waitingForItems = 2
env.RefreshList()
env:Flush()
check(env.listScrollFrame.empty.text == "Waiting 2" and env.listScrollFrame.empty.shown, "cold item data displays its loading hint after layout")
env.ns.waitingForItems = 0
env.RefreshList()
env:Flush()
check(env.listScrollFrame.empty.shown and visibleRows(env.listRows) == 0, "empty bags display the empty state")
env:Fill(2)
env.RefreshList()
env:Flush()
check(visibleRows(env.listRows) == 2 and not env.listScrollFrame.empty.shown, "loaded item data replaces the hint on the scheduled draw")

env.mainContent:AnchorMainTitle()
check(env.mainFrame.title.points.LEFT[1] == env.titleBrand and not env.mainFrame.title.points.RIGHT, "the version follows the natural title width on the left")
env.mainFrame.title:SetPoint("RIGHT", env.mainContent, "RIGHT", -12, 0)
env.mainContent:AnchorMainTitle()
check(not env.mainFrame.title.points.RIGHT, "returning from the profession tab removes the stretched title anchor")
env.mainFrame.TitleBar.version = nil
env.mainContent:AnchorMainTitle()
check(env.mainFrame.title.points.RIGHT[1] == env.blacklistOpenButton, "the header without a version retains its action-button boundary")

local clicks = environment()
clicks:Fill(2)
clicks.RefreshUI()
clicks:Flush()
local collapsed, stable = 0, true
clicks.geometryObserver = function()
    if clicks.listScrollFrame:IsVisible() and (clicks.listScrollFrame:GetWidth() <= 0 or clicks.listScrollFrame:GetHeight() <= 0) then
        collapsed = collapsed + 1
    end
end
for _ = 1, 32 do
    clicks.listRows[1]:Run("OnClick")
    clicks:Flush()
    stable = stable and visibleRows(clicks.listRows) == 2 and #clicks.queue == 1
    clicks.mainContent.selectAllButton:Run("OnClick")
    clicks:Flush()
    stable = stable and visibleRows(clicks.listRows) == 2 and #clicks.queue == 1
    clicks.mainContent.clearSelectionButton:Run("OnClick")
    clicks:Flush()
    stable = stable and visibleRows(clicks.listRows) == 2 and #clicks.queue == 0
end
check(collapsed == 0, "selection cycles must never detach or collapse the visible item viewport between layout mutations")
check(stable and #clicks.timers == 0, "32 select/best-picks/clear cycles keep both items visible without resizing")
clicks.mainContent.selectAllButton:Run("OnClick")
clicks:Flush()
local listWrites, queueWrites = clicks.listPanel.geometryWrites, clicks.queuePanel.geometryWrites
clicks.listRows[2]:Run("OnClick")
clicks:Flush()
check(clicks.listPanel.geometryWrites == listWrites and clicks.queuePanel.geometryWrites == queueWrites, "selection changes within a nonempty queue do not rebuild panel anchors")
local beforeScans, beforeEstimates = clicks.scans, clicks.estimates
local ok, detail = clicks.DescribeTestViewport(clicks.listScrollFrame, clicks.listRows, #clicks.items)
check(ok and detail:find("items 2, rows 2/2", 1, true), "viewport diagnostics capture the current populated display")
check(clicks.scans == beforeScans and clicks.estimates == beforeEstimates and #clicks.timers == 0, "viewport diagnostics do not rescan or repair the state being inspected")
for _, row in ipairs(clicks.listRows) do row:Hide() end
ok, detail = clicks.DescribeTestViewport(clicks.listScrollFrame, clicks.listRows, #clicks.items)
check(not ok and detail:find("items 2, rows 0/0", 1, true), "viewport diagnostics distinguish populated data from hidden rows")

local hover = environment()
hover.ITEM_QUALITY_COLORS = {
    [2] = {r = 0.12, g = 1, b = 0, hex = "|cff1eff00"},
    [3] = {r = 0, g = 0.44, b = 0.87, hex = "|cff0070dd"},
}
hover.ns.Prediction.AppendToTooltip = function(tooltip, item) tooltip.previewItem = item end
hover:Fill(100)
for slot, item in ipairs(hover.items) do
    item.bag, item.slot = 0, slot
    hover.selected[item.key] = true
end
hover.items[2].quality = 3
hover.items[3].quality = nil
hover.BuildQueue()
hover.RefreshUI()
hover:Flush()
local queueRow = hover.queueRows[1]
local tooltip = hover.GameTooltip
check(queueRow.mouseMotion and not queueRow.mouse, "queue rows receive hover without enabling mouse clicks")
check(queueRow.label.text == "1. |cff1eff00Item 1|r", "the first queued item uses its quality color")
check(hover.queueRows[2].label.text == "2. |cff0070ddItem 2|r", "subsequent names use their own quality colors")
check(hover.queueRows[3].label.text == "3. Item 3", "an item without known quality keeps its readable name")
queueRow:Run("OnEnter")
check(tooltip:IsOwned(queueRow) and tooltip.shown and tooltip.bag == 0 and tooltip.slot == 1 and tooltip.previewItem == queueRow.item,
    "hover opens the current bag item and its material preview")
hover.queueScrollFrame.bar:Run("OnValueChanged", 1)
hover:Flush()
check(tooltip:IsOwned(queueRow) and tooltip.slot == 2 and tooltip.previewItem == queueRow.item,
    "scrolling a hovered queue row replaces the tooltip with the new item")
queueRow:Run("OnLeave")
check(not tooltip.shown, "leaving a queue row closes its tooltip")
hover.db.showExpected = false
hover.combat = true
queueRow:Run("OnEnter")
check(tooltip.shown and tooltip.slot == 2 and not tooltip.previewItem, "the standard item tooltip works in combat with previews disabled")
queueRow:Hide()
check(not tooltip.shown, "hiding the hovered row closes its tooltip")
tooltip:SetOwner(hover.listRows[1])
tooltip:Show()
queueRow:Run("OnLeave")
check(tooltip:IsOwned(hover.listRows[1]) and tooltip.shown, "leaving a queue row preserves another frame's tooltip")

return assertions
