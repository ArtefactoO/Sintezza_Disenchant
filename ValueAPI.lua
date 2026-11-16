local _, ns = ...

Sintezza_DisenchantAPI = {
    version = 1,
    IsDisenchantBlocked = function(item)
        return type(item) == "table" and ns.IsDisenchantBlocked and ns.IsDisenchantBlocked(item) or false
    end,
    GetDisenchantEstimate = function(item)
        if Sintezza_DisenchantAPI.IsDisenchantBlocked(item) then return end
        local estimate = ns.Prediction.Estimate(item)
        if not estimate then return end
        return estimate.ev, estimate.missing, estimate.foreverAssumption
    end,
}
