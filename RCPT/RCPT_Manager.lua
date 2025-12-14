-- RCPT_Manager.lua
-- Centralized load/unload manager for RCPT modules.

-- Expected SavedVariables are declared in the root TOC (RCPT.toc):
-- `RCPT_Config`, `RCPT_TalentCheckDB`.

local f = CreateFrame("Frame")

RCPT_Config = RCPT_Config or {}
RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}

local MODULES = {
    Main = "RCPT-PullTimers",
    Talent = "RCPT-TalentCheck",
}

-- Prefer modern namespaced AddOn APIs (e.g. Midnight) but fall back to globals
local function RCPT_IsAddOnLoaded(addonName)
    if C_AddOns and type(C_AddOns.IsAddOnLoaded) == "function" then
        return C_AddOns.IsAddOnLoaded(addonName)
    elseif type(IsAddOnLoaded) == "function" then
        return IsAddOnLoaded(addonName)
    end
    return false
end

local function RCPT_LoadAddOn(addonName)
    if C_AddOns and type(C_AddOns.LoadAddOn) == "function" then
        return C_AddOns.LoadAddOn(addonName)
    elseif type(LoadAddOn) == "function" then
        return LoadAddOn(addonName)
    end
    return nil, "NO_API"
end

-- Track modules whose loads were deferred due to combat
local deferredLoads = {}

local function RetryDeferredLoads()
    for addonName,_ in pairs(deferredLoads) do
        -- attempt to load each deferred addon; clear entry on success or error
        if not RCPT_IsAddOnLoaded(addonName) then
            local ok, reason = RCPT_LoadAddOn(addonName)
            if ok then
                deferredLoads[addonName] = nil
                print("|cff00ccff[RCPT]|r  Deferred module loaded:", addonName)
            else
                print("|cff00ccff[RCPT]|r  Retry failed for deferred module:", addonName, reason)
            end
        else
            deferredLoads[addonName] = nil
        end
    end
end

local function IsInGroup()
    -- call the global API directly to avoid shadowing
    if _G.IsInGroup then return _G.IsInGroup() end
    if _G.IsInRaid then return _G.IsInRaid() end
    return false
end

local function LoadModule(addonName)
    if not addonName then return end
    if RCPT_IsAddOnLoaded(addonName) then return true end
    if InCombatLockdown() then
        -- Defer load until out of combat; remember which module we need
        deferredLoads[addonName] = true
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
        return false, "IN_COMBAT"
    end
    local ok, reason = RCPT_LoadAddOn(addonName)
    if ok and deferredLoads[addonName] then deferredLoads[addonName] = nil end
    return ok, reason
end

local function TeardownModule(addonName)
    if not addonName then return end
    -- Call known teardown hooks where available
    if addonName == MODULES.Main then
        if _G.RCPT_Teardown then pcall(_G.RCPT_Teardown)
            -- nil-out the global teardown reference to avoid stale hooks
            _G.RCPT_Teardown = nil
        end
    elseif addonName == MODULES.Talent then
        if _G.RCPT_TalentTeardown then pcall(_G.RCPT_TalentTeardown)
            _G.RCPT_TalentTeardown = nil
        end
    end
end

local function EnsureModulesForGroup()
    if IsInGroup() then
        -- Load main first
        if not RCPT_IsAddOnLoaded(MODULES.Main) then
            local ok, r = LoadModule(MODULES.Main)
            if not ok and r ~= "IN_COMBAT" then print("|cff00ccff[RCPT]|r Failed to load module:", MODULES.Main, r) end
        end
        -- Load talent module as well
        if not RCPT_IsAddOnLoaded(MODULES.Talent) then
            local ok2, r2 = LoadModule(MODULES.Talent)
            if not ok2 and r2 ~= "IN_COMBAT" then print("|cff00ccff[RCPT]|r Failed to load module:", MODULES.Talent, r2) end
        end
    else
        -- Not in group: request teardown of loaded modules
        if RCPT_IsAddOnLoaded(MODULES.Talent) then TeardownModule(MODULES.Talent) end
        if RCPT_IsAddOnLoaded(MODULES.Main) then TeardownModule(MODULES.Main) end
    end
end

f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        C_Timer.After(0.05, EnsureModulesForGroup)
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- group membership changed
        C_Timer.After(0.05, EnsureModulesForGroup)
    elseif event == "PLAYER_REGEN_ENABLED" then
        f:UnregisterEvent("PLAYER_REGEN_ENABLED")
        -- retry only deferred loads; fall back to EnsureModulesForGroup to be safe
        RetryDeferredLoads()
        C_Timer.After(0.05, EnsureModulesForGroup)
    end
end)

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("GROUP_ROSTER_UPDATE")

-- Public API
_G.RCPT_Manager = {
    LoadModule = LoadModule,
    TeardownModule = TeardownModule,
    EnsureModulesForGroup = EnsureModulesForGroup,
    Modules = MODULES,
}

-- Force-load slash for testing
SLASH_RCPTMANAGER1 = "/rcptload"
function SlashCmdList.RCPTMANAGER(msg)
    EnsureModulesForGroup()
end

print("|cff00ccff[RCPT]|r Manager initialized")
