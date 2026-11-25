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
    local db = (_G.RCPT and _G.RCPT.db) or RCPT_Config
    if db and db.debug then
        print("|cff00ccff[RCPT]|r " .. tostring(msg))
    end
end

-- Module constants
local MODULES = {
    Main = "RCPT_PullTimers",
    Talent = "RCPT_TalentCheck",
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

-- Track whether player was previously in an instance so we fire once per join
local lastInInstance = false

-- Forward declaration: RetryDeferredLoads (below) needs LoadModule, which is defined later.
local LoadModule

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

LoadModule = function(addonName)
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
    if ok and _G.RCPT and _G.RCPT.InitModules then
        pcall(function() _G.RCPT:InitModules() end)
    end
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
        if _G.RCPT and _G.RCPT.EnsureDefaults then
            pcall(function() _G.RCPT:EnsureDefaults() end)
        elseif RCPT_InitDefaults then
            pcall(RCPT_InitDefaults)
        end
        if _G.RCPT and _G.RCPT.InitModules then
            pcall(function() _G.RCPT:InitModules() end)
        end
        C_Timer.After(0.05, EnsureModulesForGroup)
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Detect zoning into an instance (dungeon/raid/scenario) and fire once
        local inInstance, instanceType = false, nil
        if type(IsInInstance) == "function" then
            inInstance, instanceType = IsInInstance()
        else
            local ok, v = pcall(GetInstanceInfo)
            if ok and v then inInstance = true end
        end
        if inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario") then
            if not lastInInstance then
                lastInInstance = true
                local db = (_G.RCPT and _G.RCPT.db) or RCPT_Config
                if db and db.resetOnDungeonJoin then
                    pcall(function()
                        if C_DamageMeter and type(C_DamageMeter.ResetAllCombatSessions) == "function" then
                            C_DamageMeter.ResetAllCombatSessions()
                            _G.RCPT_Debug("Reset damage meter sessions on dungeon join")
                        end
                    end)
                end
            end
        else
            lastInInstance = false
        end
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
f:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Public API
_G.RCPT_Manager = {
    LoadModule = LoadModule,
    TeardownModule = TeardownModule,
    EnsureModulesForGroup = EnsureModulesForGroup,
    Modules = MODULES,
}

-- Load a module by key ("Main" or "Talent") right now if it is not loaded yet.
-- Respects the combat deferral in LoadModule. Returns true when the module is loaded,
-- otherwise false plus a reason (e.g. "IN_COMBAT").
function _G.RCPT.EnsureModule(key)
    local addonName = MODULES[key]
    if not addonName then return false, "UNKNOWN_MODULE" end
    if RCPT_IsAddOnLoaded(addonName) then
        -- Loaded but torn down (left the group): re-attach it the same way EnsureModulesForGroup does.
        if key == "Main" then
            if not _G.RCPT_MainActive and type(_G.RCPT_Initialize) == "function" then
                pcall(_G.RCPT_Initialize)
            end
        elseif key == "Talent" then
            if not _G.RCPT_TalentActive and type(_G.RCPT_TalentInitialize) == "function" then
                pcall(_G.RCPT_TalentInitialize)
            end
        end
        return true
    end
    local _, reason = LoadModule(addonName)
    if RCPT_IsAddOnLoaded(addonName) then return true end
    return false, reason or "NOT_LOADED"
end

-- Always-loaded /rcpt handler. The pull-timer module replaces SlashCmdList.RCPT with the
-- full handler when it loads; until then this stub opens the options panel, or loads the
-- module and forwards the command to the real handler.
SLASH_RCPT1 = "/rcpt"
local function RCPT_SlashStub(msg)
    msg = msg or ""
    local cmd = msg:match("^%s*(%S+)")
    cmd = cmd and cmd:lower() or nil
    if cmd == "options" or cmd == "config" or cmd == "opt" then
        local opts = _G.RCPT_Options
        if opts and type(opts.Open) == "function" then
            opts.Open()
        else
            print("|cff00ccff[RCPT]|r The options panel is not available.")
        end
        return
    end

    local loaded, reason = _G.RCPT.EnsureModule("Main")
    local handler = SlashCmdList["RCPT"]
    if loaded and type(handler) == "function" and handler ~= RCPT_SlashStub then
        handler(msg)
    elseif reason == "IN_COMBAT" then
        print("|cff00ccff[RCPT]|r The pull timer module will load after combat. Try again then.")
    else
        print("|cff00ccff[RCPT]|r The pull timer module could not be loaded. Use /rcpt options for settings.")
    end
end
SlashCmdList["RCPT"] = RCPT_SlashStub

-- Force-load slash for testing
SLASH_RCPTMANAGER1 = "/rcptload"
function SlashCmdList.RCPTMANAGER(msg)
    EnsureModulesForGroup()
end

_G.RCPT_Debug("Manager initialized")
