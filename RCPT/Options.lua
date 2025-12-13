-- RCPT Options panel
-- Presents basic controls for RCPT_Config and the TalentCheck settings

local ADDON = "RCPT"

-- Ensure saved tables exist
RCPT_Config = RCPT_Config or {}
RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}

-- Local helpers
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
end

local function EnsureTalentDefaults()
    if _G.RCPT_TalentCheck and _G.RCPT_TalentCheck.EnsureDB then
        pcall(_G.RCPT_TalentCheck.EnsureDB)
        return
    end
    RCPT_TalentCheckDB.SendPartyChatNotification = RCPT_TalentCheckDB.SendPartyChatNotification == nil and false or RCPT_TalentCheckDB.SendPartyChatNotification
    RCPT_TalentCheckDB.MinDurabilityPercent = RCPT_TalentCheckDB.MinDurabilityPercent or 80
end

EnsureConfigDefaults()
EnsureTalentDefaults()

-- Build the panel
local panel = CreateFrame("Frame", "RCPTOptionsPanel", UIParent)
panel.name = "RCPT"

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("RCPT — Options")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
subtitle:SetText("General settings for RCPT addon.")

-- Row helper positions
local leftColX = 16
local rightColX = 300
local currentY = -60
local function placeNext(frame)
    frame:SetPoint("TOPLEFT", panel, "TOPLEFT", leftColX, currentY)
    currentY = currentY - 36
end

-- Debug checkbox
local cbDebug = CreateFrame("CheckButton", "RCPT_DebugCB", panel, "InterfaceOptionsCheckButtonTemplate")
cbDebug.Text:SetText("Enable debug logging")
placeNext(cbDebug)
cbDebug:SetScript("OnClick", function(self)
    RCPT_Config.debug = self:GetChecked() and true or false
end)

-- Pull Duration slider
local pullSlider = CreateFrame("Slider", "RCPT_PullDurationSlider", panel, "OptionsSliderTemplate")
pullSlider:SetWidth(220)
pullSlider:SetMinMaxValues(1, 60)
pullSlider:SetValueStep(1)
pullSlider.Text = _G[pullSlider:GetName() .. "Text"]
pullSlider.Low = _G[pullSlider:GetName() .. "Low"]
pullSlider.High = _G[pullSlider:GetName() .. "High"]
pullSlider.Text:SetText("Pull duration (seconds)")
pullSlider.Low:SetText("1")
pullSlider.High:SetText("60")
pullSlider:SetScript("OnValueChanged", function(self, v)
    local val = math.floor(v + 0.5)
    RCPT_Config.pullDuration = val
    if self.Value then self.Value:SetText(tostring(val)) end
end)
pullSlider:SetPoint("TOPLEFT", panel, "TOPLEFT", rightColX, -60)
-- numeric value display for pull duration
do
    local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", pullSlider, "RIGHT", 8, 0)
    fs:SetText(tostring(RCPT_Config.pullDuration or 10))
    pullSlider.Value = fs
end

-- Retry timeout slider
local retrySlider = CreateFrame("Slider", "RCPT_RetryTimeoutSlider", panel, "OptionsSliderTemplate")
retrySlider:SetWidth(220)
retrySlider:SetMinMaxValues(1, 120)
retrySlider:SetValueStep(1)
retrySlider.Text = _G[retrySlider:GetName() .. "Text"]
retrySlider.Low = _G[retrySlider:GetName() .. "Low"]
retrySlider.High = _G[retrySlider:GetName() .. "High"]
retrySlider.Text:SetText("Retry timeout (seconds)")
retrySlider.Low:SetText("1")
retrySlider.High:SetText("120")
retrySlider:SetScript("OnValueChanged", function(self, v)
    local val = math.floor(v + 0.5)
    RCPT_Config.retryTimeout = val
    if self.Value then self.Value:SetText(tostring(val)) end
end)
retrySlider:SetPoint("TOPLEFT", panel, "TOPLEFT", rightColX, -100)
-- numeric value display for retry timeout
do
    local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", retrySlider, "RIGHT", 8, 0)
    fs:SetText(tostring(RCPT_Config.retryTimeout or 15))
    retrySlider.Value = fs
end

-- Max retries slider
local maxRetriesSlider = CreateFrame("Slider", "RCPT_MaxRetriesSlider", panel, "OptionsSliderTemplate")
maxRetriesSlider:SetWidth(220)
maxRetriesSlider:SetMinMaxValues(0, 10)
maxRetriesSlider:SetValueStep(1)
maxRetriesSlider.Text = _G[maxRetriesSlider:GetName() .. "Text"]
maxRetriesSlider.Low = _G[maxRetriesSlider:GetName() .. "Low"]
maxRetriesSlider.High = _G[maxRetriesSlider:GetName() .. "High"]
maxRetriesSlider.Text:SetText("Max retries")
maxRetriesSlider.Low:SetText("0")
maxRetriesSlider.High:SetText("10")
maxRetriesSlider:SetScript("OnValueChanged", function(self, v)
    local val = math.floor(v + 0.5)
    RCPT_Config.maxRetries = val
    if self.Value then self.Value:SetText(tostring(val)) end
end)
maxRetriesSlider:SetPoint("TOPLEFT", panel, "TOPLEFT", rightColX, -140)
-- numeric value display for max retries
do
    local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", maxRetriesSlider, "RIGHT", 8, 0)
    fs:SetText(tostring(RCPT_Config.maxRetries or 2))
    maxRetriesSlider.Value = fs
end

-- Cancel keywords editbox (comma separated)
local kwLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
kwLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", leftColX, -120)
kwLabel:SetText("Cancel keywords (comma-separated)")

local kwBox = CreateFrame("EditBox", "RCPT_CancelKeywordsBox", panel, "InputBoxTemplate")
kwBox:SetSize(260, 22)
kwBox:SetPoint("TOPLEFT", kwLabel, "BOTTOMLEFT", 0, -6)
kwBox:SetAutoFocus(false)
-- in case the user presses Enter, just clear focus to trigger the save handler
kwBox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
end)

-- save keywords
kwBox:SetScript("OnEditFocusLost", function(self)
    local text = self:GetText() or ""
    local t = {}
    for word in text:gmatch("%s*([^,]+)%s*") do
        word = word:gsub("^%s+",""):gsub("%s+$","")
        if word ~= "" then table.insert(t, word) end
    end
    RCPT_Config.cancelKeywords = t
end)

-- TalentCheck group title
local tTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
tTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", leftColX, -200)
tTitle:SetText("TalentCheck settings")

-- Send party chat checkbox
local cbParty = CreateFrame("CheckButton", "RCPT_Talent_SendPartyCB", panel, "InterfaceOptionsCheckButtonTemplate")
cbParty.Text:SetText("Send loadout notification to party")
cbParty:SetPoint("TOPLEFT", tTitle, "BOTTOMLEFT", 0, -8)
cbParty:SetScript("OnClick", function(self)
    RCPT_TalentCheckDB.SendPartyChatNotification = self:GetChecked() and true or false
end)


-- Min durability slider
local minDurSlider = CreateFrame("Slider", "RCPT_MinDurSlider", panel, "OptionsSliderTemplate")
minDurSlider:SetWidth(220)
minDurSlider:SetMinMaxValues(5, 100)
minDurSlider:SetValueStep(5)
minDurSlider.Text = _G[minDurSlider:GetName() .. "Text"]
minDurSlider.Low = _G[minDurSlider:GetName() .. "Low"]
minDurSlider.High = _G[minDurSlider:GetName() .. "High"]
minDurSlider.Text:SetText("Min durability (%)")
minDurSlider.Low:SetText("5")
minDurSlider.High:SetText("100")
minDurSlider:SetPoint("TOPLEFT", cbParty, "TOPLEFT", 0, -36)
minDurSlider:SetScript("OnValueChanged", function(self, v)
    local val = math.floor(v + 0.5)
    RCPT_TalentCheckDB.MinDurabilityPercent = val
    if self.Value then self.Value:SetText(tostring(val)) end
end)
-- numeric value display for min durability
do
    local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", minDurSlider, "RIGHT", 8, 0)
    fs:SetText(tostring(RCPT_TalentCheckDB.MinDurabilityPercent or 80))
    minDurSlider.Value = fs
end

-- Replace default ReadyCheck checkbox
local cbReplace = CreateFrame("CheckButton", "RCPT_Talent_ReplaceReadyCB", panel, "InterfaceOptionsCheckButtonTemplate")
cbReplace.Text:SetText("Replace default Ready Check")
cbReplace:SetPoint("TOPLEFT", minDurSlider, "BOTTOMLEFT", 0, -12)
cbReplace:SetScript("OnClick", function(self)
    RCPT_TalentCheckDB.ReplaceReadyCheck = self:GetChecked() and true or false
end)

-- Panel refresh and defaults
function panel.refresh()
    EnsureConfigDefaults()
    EnsureTalentDefaults()

    cbDebug:SetChecked(not not RCPT_Config.debug)
    pullSlider:SetValue(RCPT_Config.pullDuration or 10)
    retrySlider:SetValue(RCPT_Config.retryTimeout or 15)
    maxRetriesSlider:SetValue(RCPT_Config.maxRetries or 2)

    if pullSlider.Value then pullSlider.Value:SetText(tostring(RCPT_Config.pullDuration or 10)) end
    if retrySlider.Value then retrySlider.Value:SetText(tostring(RCPT_Config.retryTimeout or 15)) end
    if maxRetriesSlider.Value then maxRetriesSlider.Value:SetText(tostring(RCPT_Config.maxRetries or 2)) end

    local kws = RCPT_Config.cancelKeywords or {}
    kwBox:SetText(table.concat(kws, ", "))

    cbParty:SetChecked(not not RCPT_TalentCheckDB.SendPartyChatNotification)
    minDurSlider:SetValue(RCPT_TalentCheckDB.MinDurabilityPercent or 80)
    if minDurSlider.Value then minDurSlider.Value:SetText(tostring(RCPT_TalentCheckDB.MinDurabilityPercent or 80)) end
    cbReplace:SetChecked(not not RCPT_TalentCheckDB.ReplaceReadyCheck)
end

function panel.default()
    RCPT_Config.pullDuration = 10
    RCPT_Config.retryTimeout = 15
    RCPT_Config.maxRetries = 2
    RCPT_Config.debug = true
    RCPT_Config.cancelKeywords = { "stop", "wait", "hold" }

    RCPT_TalentCheckDB.SendPartyChatNotification = false
    RCPT_TalentCheckDB.MinDurabilityPercent = 80
    RCPT_TalentCheckDB.ReplaceReadyCheck = true
    panel.refresh()
end

-- Test overlay button (shows the overlay using the same handler)
local testBtn = CreateFrame("Button", "RCPT_Talent_TestOverlay", panel, "UIPanelButtonTemplate")
testBtn:SetSize(140, 22)
testBtn:SetPoint("TOPLEFT", cbReplace, "TOPLEFT", 220, 0)
testBtn:SetText("Test Ready Check")
testBtn:SetScript("OnClick", function()
    pcall(function()
        if _G.RCPT_TalentCheck and _G.RCPT_TalentCheck.SimulateReadyCheckEvent then
            _G.RCPT_TalentCheck.SimulateReadyCheckEvent()
        elseif _G.RCPT_TalentCheck and _G.RCPT_TalentCheck.TriggerReadyCheck then
            _G.RCPT_TalentCheck.TriggerReadyCheck()
        end
    end)
end)

-- Register the panel with Interface Options (try legacy API then Settings)
if InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
else
    -- Try to load Blizzard module then fallback to Settings API
    if LoadAddOn then pcall(LoadAddOn, "Blizzard_InterfaceOptions") end
    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    elseif Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptionsFramePanelContainer then
        panel:SetParent(InterfaceOptionsFramePanelContainer)
    end
end

-- Optional slash to open the panel
SlashCmdList.RCPTOPTIONS = function(msg)
    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
        return
    end
    if Settings and panel and panel.Refresh then
        if panel.Show then panel:Show() end
    elseif InterfaceOptionsFrame then
        InterfaceOptionsFrame:Show()
    end
end
SLASH_RCPTOPTIONS1 = "/rcptoptions"
SLASH_RCPTOPTIONS2 = "/rcptcfg"

-- Ensure refresh runs when panel is shown
panel:SetScript("OnShow", function(self) self.refresh() end)
