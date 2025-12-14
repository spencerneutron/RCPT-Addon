-- RCPT Options panel
-- Presents basic controls for RCPT_Config and TalentCheck settings
-- RCPT Options panel (builder-backed)
local ADDON = "RCPT"

-- Saved variables (ensure exist)
RCPT_Config = RCPT_Config or {}
RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}

-- Defaults
local function EnsureConfigDefaults()
    if RCPT_InitDefaults then
        pcall(RCPT_InitDefaults)
        return
    end
    RCPT_Config.pullDuration = RCPT_Config.pullDuration or 10
    RCPT_Config.retryTimeout = RCPT_Config.retryTimeout or 15
    RCPT_Config.maxRetries = RCPT_Config.maxRetries or 2
    RCPT_Config.debug = RCPT_Config.debug == nil and true or RCPT_Config.debug
    RCPT_Config.cancelKeywords = RCPT_Config.cancelKeywords or { "stop", "wait", "hold" }
    RCPT_Config.maxRequiredGroup = RCPT_Config.maxRequiredGroup or 4
end

local function EnsureTalentDefaults()
    if _G.RCPT_TalentCheck and _G.RCPT_TalentCheck.EnsureDB then
        pcall(_G.RCPT_TalentCheck.EnsureDB)
        return
    end
    RCPT_TalentCheckDB.SendPartyChatNotification = RCPT_TalentCheckDB.SendPartyChatNotification == nil and false or RCPT_TalentCheckDB.SendPartyChatNotification
    RCPT_TalentCheckDB.MinDurabilityPercent = RCPT_TalentCheckDB.MinDurabilityPercent or 80
    RCPT_TalentCheckDB.ReplaceReadyCheck = RCPT_TalentCheckDB.ReplaceReadyCheck == nil and true or RCPT_TalentCheckDB.ReplaceReadyCheck
end

EnsureConfigDefaults()
EnsureTalentDefaults()

-- Use global builder exported by OptionsBuilder.lua
local Builder = _G.RCPT_OptionsBuilder
local b = Builder.New("RCPTOptionsPanel", UIParent, {leftX = 16, rightX = 300, startY = -60, width = 220})

b.panel.name = "RCPT"
b:AddTitle("RCPT Options")
b:AddSubtitle("General settings for RCPT addon.")

-- Group general settings under a section header
b:AddSection("General")

local cbDebug = b:AddCheck("RCPT_DebugCB", {
    label = "Enable debug logging",
    get = function() return RCPT_Config.debug end,
    set = function(v) RCPT_Config.debug = v end,
})

local pullSlider = b:AddSlider("RCPT_PullDurationSlider", {
    min = 1, max = 60, step = 1, label = "Pull timer duration (sec)",
    get = function() return RCPT_Config.pullDuration end,
    set = function(v) RCPT_Config.pullDuration = v end,
})

local retrySlider = b:AddSlider("RCPT_RetryTimeoutSlider", {
    min = 1, max = 120, step = 1, label = "Retry timeout (sec)",
    get = function() return RCPT_Config.retryTimeout end,
    set = function(v) RCPT_Config.retryTimeout = v end,
})

local maxRetriesSlider = b:AddSlider("RCPT_MaxRetriesSlider", {
    min = 0, max = 10, step = 1, label = "Max retries",
    get = function() return RCPT_Config.maxRetries end,
    set = function(v) RCPT_Config.maxRetries = v end,
})

local maxGroupSlider = b:AddSlider("RCPT_MaxRequiredGroupSlider", {
    min = 0, max = 8, step = 1, label = "Only Check Raid Group 1 through: (0 = all)",
    get = function() return RCPT_Config.maxRequiredGroup end,
    set = function(v) RCPT_Config.maxRequiredGroup = v end,
})

local kwBox = b:AddEditBox("RCPT_CancelKeywordsBox", {
    width = 260,
    get = function() return table.concat(RCPT_Config.cancelKeywords or {}, ", ") end,
    onEnter = true,
    onSave = function(text)
        local t = {}
        for word in text:gmatch("%s*([^,]+)%s*") do
            word = word:gsub("^%s+", ""):gsub("%s+$", "")
            if word ~= "" then table.insert(t, word) end
        end
        RCPT_Config.cancelKeywords = t
    end,
})

-- TalentCheck section (sub-title)
-- TalentCheck section
b:AddSection("TalentCheck settings")

local cbParty = b:AddCheck("RCPT_Talent_SendPartyCB", {
    label = "Send loadout notification to party",
    get = function() return RCPT_TalentCheckDB.SendPartyChatNotification end,
    set = function(v) RCPT_TalentCheckDB.SendPartyChatNotification = v end,
})

local minDurSlider = b:AddSlider("RCPT_MinDurSlider", {
    min = 5, max = 100, step = 5, label = "Min durability (%)",
    get = function() return RCPT_TalentCheckDB.MinDurabilityPercent end,
    set = function(v) RCPT_TalentCheckDB.MinDurabilityPercent = v end,
})

local cbReplace = b:AddCheck("RCPT_Talent_ReplaceReadyCB", {
    label = "Replace default Ready Check",
    get = function() return RCPT_TalentCheckDB.ReplaceReadyCheck end,
    set = function(v) RCPT_TalentCheckDB.ReplaceReadyCheck = v end,
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

local panel = b:Finish()

-- Panel lifecycle handlers
function panel.refresh()
    EnsureConfigDefaults()
    EnsureTalentDefaults()

    cbDebug:SetChecked(not not RCPT_Config.debug)
    if pullSlider then pullSlider:SetValue(RCPT_Config.pullDuration or 10) end
    if retrySlider then retrySlider:SetValue(RCPT_Config.retryTimeout or 15) end
    if maxRetriesSlider then maxRetriesSlider:SetValue(RCPT_Config.maxRetries or 2) end
    if maxGroupSlider then maxGroupSlider:SetValue(RCPT_Config.maxRequiredGroup or 4) end

    if pullSlider and pullSlider.Value then pullSlider.Value:SetText(tostring(RCPT_Config.pullDuration or 10)) end
    if retrySlider and retrySlider.Value then retrySlider.Value:SetText(tostring(RCPT_Config.retryTimeout or 15)) end
    if maxRetriesSlider and maxRetriesSlider.Value then maxRetriesSlider.Value:SetText(tostring(RCPT_Config.maxRetries or 2)) end
    if maxGroupSlider and maxGroupSlider.Value then maxGroupSlider.Value:SetText(tostring(RCPT_Config.maxRequiredGroup or 4)) end

    local kws = RCPT_Config.cancelKeywords or {}
    if kwBox then kwBox:SetText(table.concat(kws, ", ")) end

    if cbParty then cbParty:SetChecked(not not RCPT_TalentCheckDB.SendPartyChatNotification) end
    if minDurSlider then minDurSlider:SetValue(RCPT_TalentCheckDB.MinDurabilityPercent or 80) end
    if minDurSlider and minDurSlider.Value then minDurSlider.Value:SetText(tostring(RCPT_TalentCheckDB.MinDurabilityPercent or 80)) end
    if cbReplace then cbReplace:SetChecked(not not RCPT_TalentCheckDB.ReplaceReadyCheck) end
end

function panel.default()
    RCPT_Config.pullDuration = 10
    RCPT_Config.retryTimeout = 15
    RCPT_Config.maxRetries = 2
    RCPT_Config.debug = true
    RCPT_Config.cancelKeywords = { "stop", "wait", "hold" }
    RCPT_Config.maxRequiredGroup = 4

    RCPT_TalentCheckDB.SendPartyChatNotification = false
    RCPT_TalentCheckDB.MinDurabilityPercent = 80
    RCPT_TalentCheckDB.ReplaceReadyCheck = true
    panel.refresh()
end

panel:SetScript("OnShow", function(self) self.refresh() end)
