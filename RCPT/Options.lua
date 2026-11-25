-- RCPT Options module
-- Schema for the native Settings panel (built by OptionsBuilder), Options.Open(),
-- the cancel-keyword editor dialog, and the addon-compartment entry point.
-- Registers through the Addon module mechanism: RegisterModule("Options") / Init(addon).

local Options = {}

local MAX_KEYWORDS = 10 -- matches /rcpt addkeyword

local Addon -- set in Init

local function Print(msg)
    if Addon and Addon.Print then Addon.Print(msg) else print("|cff00ccff[RCPT]|r " .. tostring(msg)) end
end

local function Debug(msg)
    if Addon and Addon.Debug then Addon.Debug(msg) end
end

local function Secs(v) return string.format("%ds", v) end
local function Pct(v) return string.format("%d%%", v) end
local function ScalePct(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
local function NotifyFrameSettings()
    if Addon and type(Addon.NotifyFrameSettings) == "function" then Addon.NotifyFrameSettings() end
end
local function Groups(v)
    if v == 0 then return "All" end
    if v == 1 then return "1" end
    return string.format("1-%d", v)
end

------------------------------------------------------------------------
-- Cancel keyword dialog
------------------------------------------------------------------------

local keywordDialog

-- "Stop, WAIT ,, hold" -> { "stop", "wait", "hold" }  (trimmed, lowercased, de-duplicated, capped)
local function ParseKeywords(text)
    local list, seen = {}, {}
    local truncated = false
    for word in tostring(text or ""):gmatch("[^,]+") do
        word = word:match("^%s*(.-)%s*$"):lower()
        if word ~= "" and not seen[word] then
            if #list >= MAX_KEYWORDS then
                truncated = true
                break
            end
            seen[word] = true
            list[#list + 1] = word
        end
    end
    return list, truncated
end

local function CurrentKeywordText()
    local kws = RCPT_Config and RCPT_Config.cancelKeywords
    if type(kws) ~= "table" then return "" end
    return table.concat(kws, ", ")
end

local function SaveKeywords()
    if not keywordDialog then return end
    local list, truncated = ParseKeywords(keywordDialog.editBox:GetText())
    RCPT_Config = RCPT_Config or {}
    RCPT_Config.cancelKeywords = list -- a NEW table, same shape the readers expect (array of strings)
    if Addon and Addon.db and Addon.db ~= RCPT_Config then Addon.db.cancelKeywords = list end
    keywordDialog:Hide()
    if #list == 0 then
        Print("Cancel keywords cleared. Nothing will cancel the pull timer from chat.")
    else
        Print("Cancel keywords: " .. table.concat(list, ", ") .. ".")
    end
    if truncated then
        Print("Only the first " .. MAX_KEYWORDS .. " keywords were kept.")
    end
end

local function CreateKeywordDialog()
    local Style = Addon and Addon.Style
    if not Style or type(Style.CreateDialog) ~= "function" then return nil end

    local dialog = Style.CreateDialog("RCPTKeywordDialog", { width = 360, height = 190 })
    dialog:SetTitle("Cancel keywords")
    local content = dialog.content

    local help = Style.CreateText(content, "small", "textDim")
    help:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    help:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    help:SetJustifyH("LEFT")
    help:SetJustifyV("TOP")
    help:SetWordWrap(true)
    help:SetText("Typing any of these in party/raid chat cancels the pull timer. Up to " .. MAX_KEYWORDS .. " words.")

    local label = Style.CreateText(content, "body", "text")
    label:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -12)
    label:SetPoint("TOPRIGHT", help, "BOTTOMRIGHT", 0, -12)
    label:SetJustifyH("LEFT")
    label:SetText("Keywords (comma separated)")

    local editBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    editBox:SetAutoFocus(false)
    editBox:SetHeight(22)
    editBox:SetMaxLetters(200)
    editBox:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -6)
    editBox:SetPoint("TOPRIGHT", label, "BOTTOMRIGHT", -4, -6)
    editBox:SetScript("OnEnterPressed", SaveKeywords)
    editBox:SetScript("OnEscapePressed", function() dialog:Hide() end)
    dialog.editBox = editBox

    local save = Style.CreateButton(content, "Save", { width = 90, variant = "primary" })
    save:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    save:SetScript("OnClick", SaveKeywords)

    local cancel = Style.CreateButton(content, "Cancel", { width = 90 })
    cancel:SetPoint("RIGHT", save, "LEFT", -8, 0)
    cancel:SetScript("OnClick", function() dialog:Hide() end)

    dialog:HookScript("OnShow", function()
        editBox:SetText(CurrentKeywordText())
        editBox:SetCursorPosition(0)
        editBox:SetFocus()
        -- InputBoxTemplate selects all text on focus; deselect and park the cursor at the end.
        editBox:HighlightText(0, 0)
        editBox:SetCursorPosition(#editBox:GetText())
    end)

    return dialog
end

function Options.OpenKeywordDialog()
    if not keywordDialog then
        if not (Addon and Addon.Style) then
            Print("The keyword editor is unavailable. Use /rcpt addkeyword <word> instead.")
            return
        end
        local ok, result = pcall(CreateKeywordDialog)
        if not ok or not result then
            Print("Could not open the keyword editor" .. (ok and "" or (": " .. tostring(result)))
                .. ". Use /rcpt addkeyword <word> instead.")
            return
        end
        keywordDialog = result
    end
    keywordDialog:Show()
end

------------------------------------------------------------------------
-- Tools buttons
------------------------------------------------------------------------

local function EnsureModule(key)
    if Addon and type(Addon.EnsureModule) == "function" then
        return Addon.EnsureModule(key)
    end
    return false
end

-- Load a module for a tool button; prints the reason and returns false when it cannot.
local function RequireModule(key, displayName)
    local ok, reason = EnsureModule(key)
    if ok then return true end
    if reason == "IN_COMBAT" then
        Print("The " .. displayName .. " module cannot load during combat. Try again after combat.")
    else
        Print("The " .. displayName .. " add-on is not enabled or failed to load.")
    end
    return false
end

local function TestReadyCheck()
    if not RequireModule("Talent", "talent check") then return end
    local tc = _G.RCPT_TalentCheck
    if tc and type(tc.SimulateReadyCheckEvent) == "function" then
        tc.SimulateReadyCheckEvent()
    elseif tc and type(tc.TriggerReadyCheck) == "function" then
        tc.TriggerReadyCheck()
    else
        Print("The ready check test is not available.")
    end
end

local function PreviewPullFrame()
    if not RequireModule("Main", "pull timer") then return end
    if Addon and type(Addon.PreviewPullFrame) == "function" then
        Addon.PreviewPullFrame()
    else
        Print("The pull timer module is not available.")
    end
end

local function ResetFramePositions()
    if RCPT_Config then RCPT_Config.pullTimerPos = nil end
    if Addon and type(Addon.ResetPullFramePosition) == "function" then
        pcall(Addon.ResetPullFramePosition)
    end
    -- Ready-check frames: never load the module here. Loaded -> its live frames move too;
    -- not loaded -> its SavedVariables are not reachable, so there is nothing to clear.
    local tc = _G.RCPT_TalentCheck
    if tc and type(tc.ResetPositions) == "function" then
        local ok, err = pcall(tc.ResetPositions)
        if not ok then Debug("Ready check ResetPositions failed: " .. tostring(err)) end
    elseif type(RCPT_TalentCheckDB) == "table" then
        RCPT_TalentCheckDB.overlayPos = nil
        RCPT_TalentCheckDB.miniPos = nil
    end
    Print("Frame positions reset.")
end

------------------------------------------------------------------------
-- Rapid Mode start / stop (options button and addon-compartment right-click)
------------------------------------------------------------------------

local function RapidModeIsActive()
    local isActive = _G.RCPT_RapidMode_IsActive
    return type(isActive) == "function" and isActive() == true
end

local function RapidButtonText()
    return RapidModeIsActive() and "Stop" or "Start"
end

-- Starts the session when it is not running, otherwise stops it. Prints the result.
function Options.ToggleRapidMode()
    if not RequireModule("Main", "pull timer") then return end
    if RapidModeIsActive() then
        if type(_G.RCPT_RapidMode_Stop) ~= "function" then
            Print("Rapid Mode is not available.")
            return
        end
        _G.RCPT_RapidMode_Stop()
        Print("Rapid Mode stopped.")
        return
    end
    if type(_G.RCPT_RapidMode_Start) ~= "function" then
        Print("Rapid Mode is not available.")
        return
    end
    local ok, reason = _G.RCPT_RapidMode_Start()
    if ok or RapidModeIsActive() then
        Print("Rapid Mode started. Use /rcpt rapid or the same button to stop it.")
    else
        Print("Rapid Mode could not start: " .. tostring(reason or "unknown reason."))
    end
end

-- Settings button: toggle, then relabel the button (the label is also evaluated on each panel layout).
local function RapidModeButtonClick(button)
    Options.ToggleRapidMode()
    if button and type(button.SetText) == "function" then
        pcall(button.SetText, button, RapidButtonText())
    end
end

------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------

local function BuildSchema()
    local REPORT_RAID = {
        { value = "NONE",    label = "Disabled" },
        { value = "RAID",    label = "Raid chat" },
        { value = "PARTY",   label = "Party chat" },
        { value = "WHISPER", label = "Self-whisper" },
        { value = "SAY",     label = "Say" },
        { value = "YELL",    label = "Yell" },
        { value = "EMOTE",   label = "Emote" },
    }
    local REPORT_PARTY = {
        { value = "NONE",    label = "Disabled" },
        { value = "PARTY",   label = "Party chat" },
        { value = "WHISPER", label = "Self-whisper" },
        { value = "SAY",     label = "Say" },
        { value = "YELL",    label = "Yell" },
        { value = "EMOTE",   label = "Emote" },
    }

    return {
        { type = "header", label = "General" },
        { type = "check", db = "config", key = "debug", label = "Debug logging",
          tooltip = "Print extra diagnostic messages about ready checks, timers and module loading to chat. Leave off unless you are troubleshooting." },
        { type = "check", db = "config", key = "resetOnDungeonJoin", label = "Reset damage meter on dungeon join",
          tooltip = "Clear the built-in damage meter sessions each time you zone into a dungeon, raid or scenario, so each run starts with fresh numbers." },

        { type = "header", label = "Appearance" },
        { type = "slider", db = "config", key = "frameScale", label = "Frame scale",
          min = 0.75, max = 1.5, step = 0.05, format = ScalePct, onChange = NotifyFrameSettings,
          tooltip = "Size of the pull timer and ready check frames. 100% is the normal size." },
        { type = "check", db = "config", key = "lockFrames", label = "Lock frames", onChange = NotifyFrameSettings,
          tooltip = "While locked, the pull timer and ready check frames cannot be dragged. Unlock to move them." },

        { type = "header", label = "Pull Timers" },
        { type = "check", db = "config", key = "enableAutoPullTimers", label = "Automatic pull timers",
          tooltip = "Start and manage pull timers automatically from ready checks. When off, pull timers only run through Rapid Mode or when you start them yourself." },
        { type = "slider", db = "config", key = "pullDuration", label = "Pull timer duration",
          min = 1, max = 60, step = 1, format = Secs,
          tooltip = "Length of the pull countdown, in seconds, once everyone is ready." },
        { type = "slider", db = "config", key = "retryTimeout", label = "Retry timeout",
          min = 1, max = 120, step = 1, format = Secs,
          tooltip = "How long to wait after a failed ready check before sending another one, in seconds. Only used while retries remain." },
        { type = "slider", db = "config", key = "maxRetries", label = "Max retries",
          min = 0, max = 10, step = 1,
          tooltip = "How many times a failed ready check is repeated automatically before giving up. 0 never retries." },
        { type = "slider", db = "config", key = "maxRequiredGroup", label = "Raid groups to check",
          min = 0, max = 8, step = 1, format = Groups,
          tooltip = "In a raid, only players in raid groups 1 through this number must be ready; players in higher groups are ignored. The value shows as 1-N (a single group is just 1), and All checks every group." },
        { type = "button", label = "Cancel keywords", buttonText = "Edit keywords",
          tooltip = "Words that cancel a running pull timer when someone types them in party or raid chat. Opens an editor; you can also use /rcpt addkeyword <word>.",
          onClick = Options.OpenKeywordDialog },

        { type = "header", label = "Rapid Mode",
          tooltip = "Rapid Mode chains pulls after wipes: it runs a countdown, sends a ready check automatically, cancels the pull if someone is not ready, and starts again after the fight. Only the group leader or an assistant can run it." },
        { type = "button", label = "Rapid Mode session", buttonText = RapidButtonText,
          tooltip = "Start or stop a Rapid Mode session. You must be in a group as leader or assistant. Same as /rcpt rapid.",
          onClick = RapidModeButtonClick },
        { type = "slider", db = "config", key = "rapidModeDuration", label = "Countdown duration",
          min = 45, max = 360, step = 5, format = Secs,
          tooltip = "Length of the countdown a Rapid Mode session starts with, in seconds, before the final ready check and pull." },
        { type = "slider", db = "config", key = "rapidModeSkipTo", label = "Skip-to target",
          min = 15, max = 45, step = 5, format = Secs,
          tooltip = "Skip (/rcpt rapid skip) jumps the Rapid Mode countdown to this many seconds before the pull, and a ready check that already passed is kept. If it has not passed, the pull still cancels when not everyone is ready with 10 seconds left, so short targets are best used once everyone is ready." },
        { type = "check", db = "config", key = "rapidModeRaidWarning", label = "Raid warning on auto-cancel",
          tooltip = "Send a raid warning when Rapid Mode cancels the pull automatically, for example after a cancel keyword or a failed ready check." },
        { type = "check", db = "config", key = "rapidDynamicTimer", label = "Dynamic timer",
          tooltip = "After a wipe, the countdown is lengthened to cover the longest short cooldown that is still running: yours and those reported by other RCPT users. It never goes below the countdown duration set above." },
        { type = "check", db = "config", key = "rapidWipePrompt", label = "Offer Rapid Mode after a wipe",
          tooltip = "When you are the group leader or an assistant and no Rapid Mode session is running, offer to start one after a wipe." },
        { type = "check", db = "config", key = "shareCooldowns", label = "Share my cooldowns",
          tooltip = "After a wipe, tell the raid leader's RCPT how long your longest short cooldown has left. Nothing else is sent." },

        { type = "header", label = "Talent Check" },
        { type = "slider", db = "talent", key = "MinDurabilityPercent", label = "Minimum durability",
          min = 5, max = 100, step = 5, format = Pct,
          tooltip = "Any equipped item below this durability percentage triggers the low-durability warning when a ready check starts." },
        { type = "check", db = "talent", key = "ReplaceReadyCheck", label = "Replace default ready check",
          tooltip = "Use the RCPT ready check window in place of Blizzard's default ready check popup." },
        { type = "dropdown", db = "talent", key = "RaidReportMode", label = "Raid talent report",
          options = REPORT_RAID,
          tooltip = "Where RCPT posts its talent loadout notice when a ready check starts while you are in a raid. Self-whisper only shows it to you." },
        { type = "dropdown", db = "talent", key = "PartyReportMode", label = "Party talent report",
          options = REPORT_PARTY,
          tooltip = "Where RCPT posts its talent loadout notice when a ready check starts while you are in a party. Self-whisper only shows it to you." },

        { type = "header", label = "Tools" },
        { type = "button", label = "Test ready check", buttonText = "Test",
          tooltip = "Simulate a ready check so you can see the ready check window without a group.",
          onClick = TestReadyCheck },
        { type = "button", label = "Preview pull frame", buttonText = "Preview",
          tooltip = "Cycle the pull timer frame through its states so you can see how it looks and move it, without a group.",
          onClick = PreviewPullFrame },
        { type = "button", label = "Reset frame positions", buttonText = "Reset",
          tooltip = "Put the pull timer and ready check frames back at their default positions.",
          onClick = ResetFramePositions },
    }
end

------------------------------------------------------------------------
-- Registration / public API
------------------------------------------------------------------------

function Options.Init(addon)
    Addon = addon or _G.RCPT
    if Options.category then return end

    local Builder = (Addon and Addon.OptionsBuilder) or _G.RCPT_OptionsBuilder
    if not Builder then
        Print("Options panel unavailable: the options builder is missing.")
        return
    end
    if type(Settings) ~= "table" then
        Print("Options panel unavailable: the Settings API is missing.")
        return
    end

    -- Saved variables are loaded and defaults merged by now (PLAYER_LOGIN, after EnsureDefaults).
    -- Make sure, in case Init runs earlier or EnsureDefaults was skipped.
    if Addon and Addon.EnsureDefaults then pcall(Addon.EnsureDefaults, Addon) end

    local ctx = {
        prefix = "RCPT",
        debug = Debug,
        dbs = {
            config = { get = function() return RCPT_Config end, defaults = (Addon and Addon.Defaults) or {} },
            talent = { get = function() return RCPT_TalentCheckDB end, defaults = (Addon and Addon.TalentDefaults) or {} },
        },
    }

    local category, reason = Builder.Register("RCPT", BuildSchema(), ctx)
    if category then
        Options.category = category
    else
        Print("Options panel registration failed: " .. tostring(reason))
    end
end

function Options.Open()
    if InCombatLockdown() then
        Print("Options cannot be opened during combat. Try again afterwards.")
        return
    end
    if Options.category and type(Settings) == "table" and type(Settings.OpenToCategory) == "function" then
        local ok = pcall(function() Settings.OpenToCategory(Options.category:GetID()) end)
        if ok then return end
    end
    Print("The options panel is unavailable. Use /rcpt help for commands.")
end

-- Call after changing settings from code (slash commands) so an open panel updates.
function Options.Refresh()
    local Builder = (Addon and Addon.OptionsBuilder) or _G.RCPT_OptionsBuilder
    if Builder and Builder.Refresh then pcall(Builder.Refresh) end
end

-- Addon compartment (TOC: AddonCompartmentFunc / FuncOnEnter / FuncOnLeave).
-- Blizzard_Minimap AddonCompartment.lua calls func(addonName, mouseButton) and
-- onEnter/onLeave(addonName, menuButton).
function RCPT_OnAddonCompartmentClick(_, mouseButton)
    if mouseButton == "RightButton" then
        Options.ToggleRapidMode()
    else
        Options.Open()
    end
end

function RCPT_OnAddonCompartmentEnter(_, menuButton)
    if not GameTooltip then return end
    GameTooltip:SetOwner(menuButton or UIParent, "ANCHOR_LEFT")
    GameTooltip:SetText("RCPT")
    GameTooltip:AddLine("Left-click: open options", 1, 1, 1)
    GameTooltip:AddLine(RapidModeIsActive() and "Right-click: stop Rapid Mode" or "Right-click: start Rapid Mode", 1, 1, 1)
    GameTooltip:Show()
end

function RCPT_OnAddonCompartmentLeave()
    if GameTooltip then GameTooltip:Hide() end
end

_G.RCPT_Options = Options

-- Register with the Addon module registry; Init runs at PLAYER_LOGIN via InitModules
if _G.RCPT and type(_G.RCPT.RegisterModule) == "function" then
    _G.RCPT:RegisterModule("Options", Options)
else
    pcall(Options.Init, _G.RCPT)
end

return Options
