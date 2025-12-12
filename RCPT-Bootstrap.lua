-- RCPT-Bootstrap.lua
-- Lightweight bootstrap: registers minimal events, preserves saved variables,
-- exposes ShouldLoad() and conditionally loads `RCPT-Main`.

local ADDON_MAIN = "RCPT-Main"
local f = CreateFrame("Frame")

-- Ensure saved vars and defaults are available (config.lua is listed in this TOC)
RCPT_Config = RCPT_Config or {}
RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}

-- Default load condition structure stored in RCPT_Config so you can tune it later
RCPT_Config.loadConditions = RCPT_Config.loadConditions or {
    enabled = true,
    classes = nil,      -- e.g. { "MAGE", "WARLOCK" }
    specs = nil,        -- spec names (best-effort), e.g. { "Frost" }
    zones = nil,        -- zone names where addon should load
    requireTalentModule = false, -- whether to auto-load talent module at main load
}

local function IsRelevantClass(list)
    if not list then return true end
    local _, playerClass = UnitClass("player")
    for _, c in ipairs(list) do
        if c == playerClass then return true end
    end
    return false
end

local function IsRelevantSpec(list)
    if not list then return true end
    if not GetSpecialization then return true end
    local specIndex = GetSpecialization()
    if not specIndex or specIndex == 0 then return false end
    local _, specName = GetSpecializationInfo(specIndex)
    for _, s in ipairs(list) do
        if s == specName then return true end
    end
    return false
end

local function IsRelevantZone(list)
    if not list then return true end
    if not GetRealZoneText then return true end
    local zone = GetRealZoneText()
    for _, z in ipairs(list) do
        if z == zone then return true end
    end
    return false
end

-- Central ShouldLoad function; you can tune RCPT_Config.loadConditions later
function ShouldLoadRCPT()
    local c = RCPT_Config.loadConditions or {}
    if c.enabled == false then return false end
    if not IsRelevantClass(c.classes) then return false end
    if not IsRelevantSpec(c.specs) then return false end
    if not IsRelevantZone(c.zones) then return false end
    return true
end

-- Attempt to load main (avoid loading during combat if it could change secure frames)
local function TryLoadMain()
    if IsAddOnLoaded(ADDON_MAIN) then return end
    if InCombatLockdown() then
        -- Defer until after combat
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    local loaded, reason = LoadAddOn(ADDON_MAIN)
    if not loaded then
        print("[RCPT] Failed to load main addon:", reason)
    else
        -- Optionally auto-load talent module if requested in load conditions
        local c = RCPT_Config.loadConditions or {}
        if c.requireTalentModule then
            if not IsAddOnLoaded("RCPT-TalentCheck") then
                local ok, r = LoadAddOn("RCPT-TalentCheck")
                if not ok then print("[RCPT] talent module load failed:", r) end
            end
        end
    end
end

local function IsPlayerInGroup()
    -- IsInGroup returns true for party or raid
    if IsInGroup and IsInGroup() then return true end
    return false
end

local function LoadModulesIfNeeded()
    if IsPlayerInGroup() then
        -- load main and talent module when joining a group
        if not IsAddOnLoaded("RCPT-Main") then
            local ok, reason = LoadAddOn("RCPT-Main")
            if not ok then print("[RCPT] Failed to load RCPT-Main:", reason) end
        end
        if not IsAddOnLoaded("RCPT-TalentCheck") then
            local ok2, r2 = LoadAddOn("RCPT-TalentCheck")
            if not ok2 then print("[RCPT] Failed to load RCPT-TalentCheck:", r2) end
        end
    else
        -- Attempt a graceful shutdown of runtime behavior in loaded modules
        if IsAddOnLoaded("RCPT-Main") and _G.RCPT_Teardown then
            pcall(_G.RCPT_Teardown)
        end
        if IsAddOnLoaded("RCPT-TalentCheck") and _G.RCPT_TalentTeardown then
            pcall(_G.RCPT_TalentTeardown)
        end
    end
end

f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        -- ensure defaults exist
        if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        C_Timer.After(0.05, function()
            -- evaluate group state immediately after login
            LoadModulesIfNeeded()
        end)
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- group membership changed — load or teardown accordingly
        C_Timer.After(0.05, function()
            LoadModulesIfNeeded()
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        f:UnregisterEvent("PLAYER_REGEN_ENABLED")
        LoadModulesIfNeeded()
    end
end)

-- We want to watch for group roster changes too
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("GROUP_ROSTER_UPDATE")

-- Make ShouldLoad available globally for quick tuning/testing
_G.RCPT_ShouldLoad = ShouldLoadRCPT

-- Minimal slash helper to force-load main for testing
SLASH_RCPTFORCE1 = "/rcptload"
function SlashCmdList.RCPTFORCE(msg)
    TryLoadMain()
end
