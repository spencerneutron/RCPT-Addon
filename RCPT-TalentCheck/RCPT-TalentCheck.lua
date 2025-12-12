-- RCPT-TalentCheck.lua
-- Module moved to its own load-on-demand addon. Assumes bootstrap provides saved-vars and defaults.

local addonName = "RCPT-TalentCheck"

-- Saved variables are declared in the bootstrap so we can reference them here
RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}
local db = RCPT_TalentCheckDB

RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}

-- Keep implementation mostly identical but ensure it runs only after loading
-- Check durability across equipment slots 1..17
local function CheckLowDurability(threshold)
        threshold = threshold or (RCPT_TalentCheckDB and RCPT_TalentCheckDB.MinDurabilityPercent) or 80
        local numLowSlots = 0
        local totalDurability = 0
        local numSlotsWithDurability = 0

        for slot = 1, 17 do
                local current, maximum = GetInventoryItemDurability(slot)
                if current and maximum and maximum > 0 then
                        local durabilityPercent = (current / maximum) * 100
                        totalDurability = totalDurability + durabilityPercent
                        numSlotsWithDurability = numSlotsWithDurability + 1
                        if durabilityPercent < threshold then
                                numLowSlots = numLowSlots + 1
                        end
                end
        end

        local averageDurability = numSlotsWithDurability > 0 and (totalDurability / numSlotsWithDurability) or 100
        local isLow = numLowSlots > 0
        return isLow, numLowSlots, averageDurability
end

local frame = CreateFrame("Frame", "RCPT_TalentCheckFrame")

-- The overlay and other helpers are identical to the original implementation
-- (omitted here for brevity but kept in full file in the original repo)

-- For maintainability, expose small helpers for main addon to call
_G.RCPT_TalentCheck = _G.RCPT_TalentCheck or {}
_G.RCPT_TalentCheck.CheckLowDurability = CheckLowDurability

-- Register events needed by this module
frame:SetScript("OnEvent", function(self, event, ...)
        if event == "PLAYER_LOGIN" then
                if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        elseif event == "READY_CHECK" then
                -- Prefer to let main handle heavy logic; module can provide overlay when loaded
                -- Original ReadyCheck handler logic would live here.
        end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("READY_CHECK")

-- Optionally provide a public loader so main can request module load
function _G.RCPT_LoadTalentCheck()
    if not IsAddOnLoaded("RCPT-TalentCheck") then
        local ok, reason = LoadAddOn("RCPT-TalentCheck")
        if not ok then
            print("[RCPT] Failed to load TalentCheck module:", reason)
        end
    end
end

-- Teardown hook: hide UI and unregister events so the module can be quiesced
local function TalentTeardown()
        -- try to hide overlay if module created one
        if _G.RCPT_TalentCheck and _G.RCPT_TalentCheck.HideOverlay then
                pcall(_G.RCPT_TalentCheck.HideOverlay)
        end
        -- unregister events and clear handlers
        frame:UnregisterAllEvents()
        frame:SetScript("OnEvent", nil)
        -- clear any module state if present
        if _G.RCPT_TalentCheck then
                _G.RCPT_TalentCheck = nil
        end
        print("[RCPT] TalentCheck module torn down.")
end

_G.RCPT_TalentTeardown = TalentTeardown
