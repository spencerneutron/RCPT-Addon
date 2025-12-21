-- RCPT Options module
-- Exposes Options.Init(addon) and registers with Addon registry when available

local Options = {}

function Options.Init(addon)
    local Addon = addon or _G.RCPT

    -- DB aliases (use Addon aliases when available, fall back to globals)
    local DB, TDB
    local function RefreshDBs()
        DB = (Addon and Addon.db) or RCPT_Config or {}
        TDB = (Addon and Addon.talentDB) or RCPT_TalentCheckDB or {}
    end
    RefreshDBs()

    local function EnsureConfigDefaults()
        if Addon and Addon.EnsureDefaults then
            pcall(function() Addon:EnsureDefaults() end)
            RefreshDBs()
            return
        end
        if RCPT_InitDefaults then
            pcall(RCPT_InitDefaults)
            RefreshDBs()
            return
        end
        DB.pullDuration = DB.pullDuration or 10
        DB.enableAutoPullTimers = DB.enableAutoPullTimers == nil and false or DB.enableAutoPullTimers
        DB.retryTimeout = DB.retryTimeout or 15
        DB.maxRetries = DB.maxRetries or 2
        DB.debug = DB.debug == nil and true or DB.debug
        DB.cancelKeywords = DB.cancelKeywords or { "stop", "wait", "hold" }
        DB.maxRequiredGroup = DB.maxRequiredGroup or 4
        DB.resetOnDungeonJoin = DB.resetOnDungeonJoin == nil and false or DB.resetOnDungeonJoin
    end

    local function EnsureTalentDefaults()
        if Addon and Addon.EnsureDefaults then
            pcall(function() Addon:EnsureDefaults() end)
            RefreshDBs()
            return
        end
        if _G.RCPT_TalentCheck and _G.RCPT_TalentCheck.EnsureDB then
            pcall(_G.RCPT_TalentCheck.EnsureDB)
            RefreshDBs()
            return
        end
        TDB.SendPartyChatNotification = TDB.SendPartyChatNotification == nil and false or TDB.SendPartyChatNotification
        TDB.MinDurabilityPercent = TDB.MinDurabilityPercent or 80
        TDB.ReplaceReadyCheck = TDB.ReplaceReadyCheck == nil and true or TDB.ReplaceReadyCheck
    end

    -- If panel already exists, refresh and return
    if _G["RCPTOptionsPanel"] then
        EnsureConfigDefaults()
        EnsureTalentDefaults()
        if _G["RCPTOptionsPanel"].refresh then pcall(_G["RCPTOptionsPanel"].refresh) end
        return
    end

    EnsureConfigDefaults()
    EnsureTalentDefaults()

    local Builder = (Addon and Addon.OptionsBuilder) or _G.RCPT_OptionsBuilder
    local b = Builder.New("RCPTOptionsPanel", UIParent, {leftX = 16, rightX = 300, startY = -60, width = 220})

    b.panel.name = "RCPT"
    b:AddTitle("RCPT Options")
    b:AddSubtitle("General settings for RCPT addon.")

    b:AddSection("General")

    -- Group general settings visually
    local g1 = nil
    if b.BeginGroup then g1 = b:BeginGroup("General Settings") end

    local cbDebug = b:AddCheck("RCPT_DebugCB", {
        label = "Enable debug logging",
        get = function() return DB.debug end,
        set = function(v) DB.debug = v end,
    })

    local cbResetOnDungeon = b:AddCheck("RCPT_ResetOnDungeonCB", {
        label = "Reset damage meter on dungeon join",
        get = function() return DB.resetOnDungeonJoin end,
        set = function(v) DB.resetOnDungeonJoin = v end,
    })

    local cbAutoPull = b:AddCheck("RCPT_AutoPullCB", {
        label = "Enable automatic pull timers",
        get = function() return DB.enableAutoPullTimers end,
        set = function(v) DB.enableAutoPullTimers = v end,
    })

    local pullSlider = b:AddSlider("RCPT_PullDurationSlider", {
        min = 1, max = 60, step = 1, label = "Pull timer duration (sec)",
        get = function() return DB.pullDuration end,
        set = function(v) DB.pullDuration = v end,
    })

    local retrySlider = b:AddSlider("RCPT_RetryTimeoutSlider", {
        min = 1, max = 120, step = 1, label = "Retry timeout (sec)",
        get = function() return DB.retryTimeout end,
        set = function(v) DB.retryTimeout = v end,
    })

    local maxRetriesSlider = b:AddSlider("RCPT_MaxRetriesSlider", {
        min = 0, max = 10, step = 1, label = "Max retries",
        get = function() return DB.maxRetries end,
        set = function(v) DB.maxRetries = v end,
    })

    local maxGroupSlider = b:AddSlider("RCPT_MaxRequiredGroupSlider", {
        min = 0, max = 8, step = 1, label = "Only Check Raid Group 1 through: (0 = all)",
        get = function() return DB.maxRequiredGroup end,
        set = function(v) DB.maxRequiredGroup = v end,
    })

    local kwBox = b:AddEditBox("RCPT_CancelKeywordsBox", {
        label = "Cancel keywords (comma separated)",
        width = 260,
        get = function() return table.concat(DB.cancelKeywords or {}, ", ") end,
        onEnter = true,
        onSave = function(text)
            local t = {}
            for word in text:gmatch("%s*([^,]+)%s*") do
                word = word:gsub("^%s+", ""):gsub("%s+$", "")
                if word ~= "" then table.insert(t, word) end
            end
            DB.cancelKeywords = t
        end,
    })
    if b.EndGroup then b:EndGroup() end

    -- visual break between general settings and talent-check related options
    if b.AddDivider then b:AddDivider() end
    b:AddSection("TalentCheck settings")

    local g2 = nil
    if b.BeginGroup then g2 = b:BeginGroup("TalentCheck") end

    local cbParty = b:AddCheck("RCPT_Talent_SendPartyCB", {
        label = "Send loadout notification to party",
        get = function() return TDB.SendPartyChatNotification end,
        set = function(v) TDB.SendPartyChatNotification = v end,
    })

    local minDurSlider = b:AddSlider("RCPT_MinDurSlider", {
        min = 5, max = 100, step = 5, label = "Min durability (%)",
        get = function() return TDB.MinDurabilityPercent end,
        set = function(v) TDB.MinDurabilityPercent = v end,
    })

    local cbReplace = b:AddCheck("RCPT_Talent_ReplaceReadyCB", {
        label = "Replace default Ready Check",
        get = function() return TDB.ReplaceReadyCheck end,
        set = function(v) TDB.ReplaceReadyCheck = v end,
    })

    b:AddButton("RCPT_Talent_TestOverlay", "Test Ready Check", 140, function()
        pcall(function()
            if _G.RCPT_TalentCheck and _G.RCPT_TalentCheck.SimulateReadyCheckEvent then
                _G.RCPT_TalentCheck.SimulateReadyCheckEvent()
            elseif _G.RCPT_TalentCheck and _G.RCPT_TalentCheck.TriggerReadyCheck then
                _G.RCPT_TalentCheck.TriggerReadyCheck()
            end
        end)
    end)

    if b.EndGroup then b:EndGroup() end

    local panel = b:Finish()

    function panel.refresh()
        EnsureConfigDefaults()
        EnsureTalentDefaults()
        cbDebug:SetChecked(not not DB.debug)
        if cbResetOnDungeon then cbResetOnDungeon:SetChecked(not not DB.resetOnDungeonJoin) end
        if cbAutoPull then cbAutoPull:SetChecked(not not DB.enableAutoPullTimers) end
        if pullSlider then pullSlider:SetValue(DB.pullDuration or 10) end
        if retrySlider then retrySlider:SetValue(DB.retryTimeout or 15) end
        if maxRetriesSlider then maxRetriesSlider:SetValue(DB.maxRetries or 2) end
        if maxGroupSlider then maxGroupSlider:SetValue(DB.maxRequiredGroup or 4) end

        if pullSlider and pullSlider.Value then pullSlider.Value:SetText(tostring(DB.pullDuration or 10)) end
        if retrySlider and retrySlider.Value then retrySlider.Value:SetText(tostring(DB.retryTimeout or 15)) end
        if maxRetriesSlider and maxRetriesSlider.Value then maxRetriesSlider.Value:SetText(tostring(DB.maxRetries or 2)) end
        if maxGroupSlider and maxGroupSlider.Value then maxGroupSlider.Value:SetText(tostring(DB.maxRequiredGroup or 4)) end

        local kws = DB.cancelKeywords or {}
        if kwBox then kwBox:SetText(table.concat(kws, ", ")) end

        if cbParty then cbParty:SetChecked(not not TDB.SendPartyChatNotification) end
        if minDurSlider then minDurSlider:SetValue(TDB.MinDurabilityPercent or 80) end
        if minDurSlider and minDurSlider.Value then minDurSlider.Value:SetText(tostring(TDB.MinDurabilityPercent or 80)) end
        if cbReplace then cbReplace:SetChecked(not not TDB.ReplaceReadyCheck) end
    end

    function panel.default()
        DB.pullDuration = 10
        DB.enableAutoPullTimers = false
        DB.retryTimeout = 15
        DB.maxRetries = 2
        DB.debug = true
        DB.cancelKeywords = { "stop", "wait", "hold" }
        DB.maxRequiredGroup = 4
        DB.resetOnDungeonJoin = false

        TDB.SendPartyChatNotification = false
        TDB.MinDurabilityPercent = 80
        TDB.ReplaceReadyCheck = true
        panel.refresh()
    end

    panel:SetScript("OnShow", function(self) self.refresh() end)
end

-- Register with Addon if available, otherwise init immediately for compatibility
if _G.RCPT and type(_G.RCPT.RegisterModule) == "function" then
    _G.RCPT:RegisterModule("Options", Options)
else
    pcall(function() Options.Init(_G.RCPT) end)
    _G.RCPT_Options = Options
end

return Options