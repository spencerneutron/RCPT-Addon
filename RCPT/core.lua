-- RCPT core.lua
-- Centralized addon table, defaults, and migration helpers

local Addon = {}
Addon.name = "RCPT"

Addon.Defaults = {
    pullDuration = 10,
    cancelKeywords = { "stop", "wait", "hold" },
    retryTimeout = 15,
    maxRetries = 1,
    debug = false,
    -- Only require readiness from raid subgroups up to this number.
    -- Set to 0 or nil to require all groups.
    maxRequiredGroup = 4,
    resetOnDungeonJoin = false,
    -- Rapid Mode defaults
    rapidModeDuration = 90,     -- Pull timer duration in seconds (45-360)
    rapidModeSkipTo = 30,       -- Skip/accelerate target in seconds (15-45)
    rapidModeRaidWarning = true, -- Send RAID_WARNING when pull is auto-canceled
    configVersion = 5
}

Addon.TalentDefaults = {
    MinDurabilityPercent = 80,
    ReplaceReadyCheck = true,
    -- Report mode when in a raid. Values: "NONE","RAID","PARTY","WHISPER","SAY","YELL","EMOTE"
    RaidReportMode = "NONE",
    -- Report mode when in a party (not raid). Values: "NONE","PARTY","WHISPER","SAY","YELL","EMOTE"
    PartyReportMode = "NONE",
}

-- Migration table: add functions keyed by the target version number.
-- e.g. migrations[2] = function(self, db, talentDB) ... end
Addon.migrations = {
    -- no-op placeholder; add migrations here when bumping configVersion
    -- v5: migrate old SendPartyChatNotification + RaidReportChannel to new RaidReportMode/PartyReportMode
    [5] = function(self, db, talentDB)
        if not talentDB then return end
        if talentDB.SendPartyChatNotification then
            -- User had notifications enabled – convert to new mode fields
            local oldRaidChannel = talentDB.RaidReportChannel or "RAID"
            talentDB.RaidReportMode = oldRaidChannel  -- "RAID" or "PARTY"
            talentDB.PartyReportMode = "PARTY"
        else
            talentDB.RaidReportMode = "NONE"
            talentDB.PartyReportMode = "NONE"
        end
        -- Clean up legacy keys
        talentDB.SendPartyChatNotification = nil
        talentDB.RaidReportChannel = nil
    end,
}

local function MergeDefaults(db, defaults)
    if not db or not defaults then return end
    for k, v in pairs(defaults) do
        if db[k] == nil then
            db[k] = v
        end
    end
end

function Addon:RunMigrations(fromVersion)
    local target = self.Defaults.configVersion or 0
    for v = (fromVersion or 0) + 1, target do
        local fn = self.migrations[v]
        if fn and type(fn) == "function" then
            pcall(fn, self, self.db or RCPT_Config, self.talentDB or RCPT_TalentCheckDB)
        end
    end
end

function Addon:EnsureDefaults()
    -- Saved vars come from the TOC; ensure they exist
    RCPT_Config = RCPT_Config or {}
    RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}

    local current = RCPT_Config.configVersion or 0
    local target = self.Defaults.configVersion or 0

    if current ~= target then
        RCPT_Debug("Config version mismatch: current=" .. tostring(current) .. ", target=" .. tostring(target))
        if current < target then
            self:RunMigrations(current)
        end
        -- always merge missing keys, even if config is newer than target
        MergeDefaults(RCPT_Config, self.Defaults)
        RCPT_Config.configVersion = target
        RCPT_Debug("Config migrated to version " .. tostring(target))
    else
        MergeDefaults(RCPT_Config, self.Defaults)
    end

    MergeDefaults(RCPT_TalentCheckDB, self.TalentDefaults)

    RCPT_Settings = RCPT_Settings or {}
    RCPT_Settings.config = RCPT_Config
    RCPT_Settings.talentCheck = RCPT_TalentCheckDB
    -- Refresh convenient aliases so modules can use `Addon.db` / `Addon.talentDB`
    if type(self.RefreshAliases) == "function" then pcall(function() self:RefreshAliases() end) end
end

-- Provide convenient aliases on the Addon table so modules can use Addon.db
-- while SavedVariables remain defined in the TOC as globals.
function Addon:RefreshAliases()
    self.db = RCPT_Config
    self.talentDB = RCPT_TalentCheckDB
    self.Settings = RCPT_Settings
end

-- Ensure aliases are set initially
Addon:RefreshAliases()

-- Compatibility exports for existing code
RCPT_Defaults = Addon.Defaults
RCPT_TalentCheckDefaults = Addon.TalentDefaults
function RCPT_InitDefaults()
    pcall(function() Addon:EnsureDefaults() end)
end

_G.RCPT = _G.RCPT or Addon

if _G.RCPT and _G.RCPT.RefreshAliases then _G.RCPT:RefreshAliases() end

-- Module registry / dependency-injection helpers
Addon.modules = Addon.modules or {}

function Addon:RegisterModule(name, mod)
    if not name or not mod then return end
    self.modules[name] = mod
    if self._modulesInitialized and type(mod.Init) == "function" then
        local ok = pcall(mod.Init, self)
        if ok then mod._initialized = true end
    end
end

function Addon:InitModule(name)
    local mod = self.modules and self.modules[name]
    if mod and type(mod.Init) == "function" then
        if mod._initialized then return true end
        local ok, err = pcall(mod.Init, self)
        if ok then mod._initialized = true end
        return ok, err
    end
    return nil, "NO_MODULE"
end

function Addon:InitModules()
    self.modules = self.modules or {}
    for name, mod in pairs(self.modules) do
        if type(mod.Init) == "function" and not mod._initialized then
            local ok = pcall(mod.Init, self)
            if ok then mod._initialized = true end
        end
    end
    self._modulesInitialized = true
end

-- Overlay frame registry: single source of truth for "is this overlay active?"
-- Modules register their overlay frames here so other modules can discover and
-- query them without hardcoding global frame names or duplicating visibility logic.
Addon.overlayFrames = Addon.overlayFrames or {}

-- Register an overlay frame.  The frame should implement :IsActiveOverlay().
function Addon:RegisterOverlayFrame(key, frame)
    if not key or not frame then return end
    self.overlayFrames[key] = frame
end

-- Unregister an overlay frame (e.g. on module teardown).
function Addon:UnregisterOverlayFrame(key)
    if self.overlayFrames then self.overlayFrames[key] = nil end
end

-- Check whether a registered overlay is currently active (shown and in use).
function Addon:IsOverlayActive(key)
    local f = self.overlayFrames and self.overlayFrames[key]
    if not f then return false end
    if type(f.IsActiveOverlay) == "function" then
        local ok, result = pcall(f.IsActiveOverlay, f)
        return ok and result == true
    end
    return false
end

-- Return the raw frame object for a registered overlay.
function Addon:GetOverlayFrame(key)
    return self.overlayFrames and self.overlayFrames[key] or nil
end

-- Safe wrapper for UnitIsUnit to protect against Secret/tainted errors
function Addon.SafeUnitIsUnit(a, b)
    if type(UnitIsUnit) ~= "function" then return false end
    local ok, res = pcall(UnitIsUnit, a, b)
    if not ok then return false end
    return res == true
end

function Addon.EncounterRestrictionsActive()
    -- For now, we'll use the latest API to check for action restrictions even if they don't necessarily apply to our specific calls

    -- state = C_RestrictedActions.GetAddOnRestrictionState(type)
    
    -- type values Enum.AddOnRestrictionType:
    --0	Combat	
    --1	Encounter	
    --2	ChallengeMode	
    --3	PvPMatch	
    --4	Map

    -- state returns Enum.AddOnRestrictionState
    --0	Inactive	
    --1	Activating	
    --2	Active

    if type(C_RestrictedActions) ~= "table" or type(C_RestrictedActions.GetAddOnRestrictionState) ~= "function" then
        return true -- assume restrictions are active if we can't check
    end
    local ok1, state1 = pcall(function() return C_RestrictedActions.GetAddOnRestrictionState(Enum.AddOnRestrictionType.Encounter) end)
    local ok2, state2 = pcall(function() return C_RestrictedActions.GetAddOnRestrictionState(Enum.AddOnRestrictionType.ChallengeMode) end)
    local ok = ok1 and ok2
    local stateValid = (state1 == Enum.AddOnRestrictionState.Inactive and state2 == Enum.AddOnRestrictionState.Inactive)
    if not ok or not stateValid then
        return true
    end
    return false
end

print("|cff00ccff[RCPT]|r Core initialized")
return Addon
