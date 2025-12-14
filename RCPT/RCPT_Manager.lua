-- RCPT_Manager.lua
-- Centralized load/unload manager for RCPT modules.

-- Expected SavedVariables are declared in the root TOC (RCPT.toc):
-- `RCPT_Config`, `RCPT_TalentCheckDB`.

local f = CreateFrame("Frame")

-- SavedVariables (declared in root TOC)
RCPT_Config = RCPT_Config or {}
RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}

-- Global debug helper (exposed to other modules)
_G.RCPT_Debug = _G.RCPT_Debug or function(msg)
    if RCPT_Config and RCPT_Config.debug then
        print("|cff00ccff[RCPT]|r " .. tostring(msg))
    end
end

-- Module constants
local MODULES = {
    Main = "RCPT-PullTimers",
    Talent = "RCPT-TalentCheck",
}

-- API adapters (prefer modern namespaced APIs when available)
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
        if RCPT_IsAddOnLoaded(addonName) then
            deferredLoads[addonName] = nil
        else
            local ok, reason = LoadModule(addonName)
            if ok then
                deferredLoads[addonName] = nil
                _G.RCPT_Debug("Deferred module loaded: " .. tostring(addonName))
            else
                _G.RCPT_Debug("Retry failed for deferred module: " .. tostring(addonName) .. " " .. tostring(reason))
            end
        end
    end
end

-- Group detection (use global APIs if present)
local function RCPT_IsInGroup()
    if type(IsInGroup) == "function" then return IsInGroup() end
    if type(IsInRaid) == "function" then return IsInRaid() end
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
        if _G.RCPT_Teardown then pcall(_G.RCPT_Teardown) end
    elseif addonName == MODULES.Talent then
        if _G.RCPT_TalentTeardown then pcall(_G.RCPT_TalentTeardown) end
    end
end

local function EnsureModulesForGroup()
    if RCPT_IsInGroup() then
        -- Load main first
        if not RCPT_IsAddOnLoaded(MODULES.Main) then
            local ok, r = LoadModule(MODULES.Main)
            if not ok and r ~= "IN_COMBAT" then _G.RCPT_Debug("Failed to load module: " .. tostring(MODULES.Main) .. " " .. tostring(r)) end
        else
            -- If the addon is loaded but not active (was torn down), attempt to re-initialize
            if not _G.RCPT_MainActive and _G.RCPT_Initialize then
                pcall(_G.RCPT_Initialize)
            end
        end

        -- Load talent module as well
        if not RCPT_IsAddOnLoaded(MODULES.Talent) then
            local ok2, r2 = LoadModule(MODULES.Talent)
            if not ok2 and r2 ~= "IN_COMBAT" then _G.RCPT_Debug("Failed to load module: " .. tostring(MODULES.Talent) .. " " .. tostring(r2)) end
        else
            if not _G.RCPT_TalentActive and _G.RCPT_TalentInitialize then
                pcall(_G.RCPT_TalentInitialize)
            end
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
        _G.RCPT_Debug("Group roster updated")
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
