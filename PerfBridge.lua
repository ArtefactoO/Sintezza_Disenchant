local addon, ns = ...
local api = _G.Sintezza_PerfAPI
if type(api) ~= "table" or api.version ~= 1 then return end
local module = api:RegisterModule(addon, "disenchant", { title = "Disenchant estimates", titleRu = "Оценка распыления" })
if not module then return end
local call = api:RegisterPoint(module, "estimate", { title = "Estimate materials", titleRu = "Оценка материалов", memory = true })
local counter = api:RegisterPoint(module, "observed", { kind = "counter", title = "Observed data lookups", titleRu = "Поиск наблюдений" })
local bridge = {}
ns.PerfBridge = bridge
function bridge.Count(key)
    if key == "observed" and counter then api:Count(counter) end
end
local owner = ns.Prediction
if call and owner and type(owner.Estimate) == "function" then
    local original = owner.Estimate
    owner.Estimate = function(...)
        if not api:IsActive(call) then return original(...) end
        if issecretvalue then
            for i = 1, select("#", ...) do
                if issecretvalue(select(i, ...)) then return original(...) end
            end
        end
        return api:Call(call, original, ...)
    end
end
