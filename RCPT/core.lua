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
    configVersion = 3
}

Addon.TalentDefaults = {
    SendPartyChatNotification = false,
    MinDurabilityPercent = 80,
    ReplaceReadyCheck = true,
}

-- Migration table: add functions keyed by the target version number.
-- e.g. migrations[2] = function(self, db, talentDB) ... end
Addon.migrations = {
    -- no-op placeholder; add migrations here when bumping configVersion
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
        RCPT_Debug("|cff00ccff[RCPT]|r Config version mismatch: current=" .. tostring(current) .. ", target=" .. tostring(target))
        if current < target then
            self:RunMigrations(current)
        end
        -- always merge missing keys, even if config is newer than target
        MergeDefaults(RCPT_Config, self.Defaults)
        RCPT_Config.configVersion = target
        RCPT_Debug("|cff00ccff[RCPT]|r Config migrated to version " .. tostring(target))
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

print("|cff00ccff[RCPT]|r Core initialized")

return Addon
