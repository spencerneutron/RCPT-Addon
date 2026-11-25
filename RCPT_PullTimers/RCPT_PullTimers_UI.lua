-- RCPT_PullTimers_UI.lua
-- Pull-timer status frame, built on the shared RCPT design system (RCPT/Style.lua).
-- Driven by callbacks from RCPT_PullTimers.lua. The only OnUpdate is the progress
-- bar, which drains smoothly while a timed phase (retry wait, pull countdown) runs.
--
-- Layout (320 px wide, TOP-anchored: height follows content and grows downwards):
--   header   "RCPT" (accent) + mode label (dim) ...... big figure (ready count / time)  [x]
--   normal   4-step stepper with status atlases, then the status line
--   rapid    status line, optional reason line (dynamic timer), optional not-ready list,
--            two button rows: -10 | +10 | Skip  /  Defer | Restart | End Rapid
--   prompt   (after a wipe, outside a session) question, suggested timer, Start Rapid | Dismiss
--   bottom   10 px draining bar with the remaining time as its label (timed phases only);
--            rapid mode adds tick markers at the ready-check moment and the 10 s cutoff
--   combat   (rapid) slim, click-through, low-alpha header strip until combat ends

local Addon = _G.RCPT

local FRAME_NAME = "RCPTPullStatusFrame"
local frame       -- main status frame (lazy-created)
local ui = {}     -- widgets: brand, mode, countdown, close, stepper, status, notReady, bar, buttons
local stepStates = {} -- per-step state mirror: "idle" | "active" | "done" | "fail"

-- Active C_Timer handles (cancelled on hide / combat)
local retryTicker
local pullTicker
local autoHideTicker
local notReadyTicker  -- ephemeral display of failed-pull offenders
local promptTimer     -- auto-hide of the post-wipe prompt
local reasonPulseTimer -- ends the short pulse on the reason line

local NOTREADY_DISPLAY_SECONDS = 10
local PROMPT_SECONDS = 20       -- post-wipe prompt auto-hides after this long
local REASON_PULSE_SECONDS = 2.4 -- two full Style.Pulse bounces (0.6 s each way)
local NOTREADY_LINE_CAP = 5  -- one name per line, this many lines, then "+N more"

-- Display-only mirror of RAPID_CUTOFF in RCPT_PullTimers.lua (cancel when the RC has
-- not passed with this many seconds left); used for the bar's cutoff tick.
local RAPID_CUTOFF_SECONDS = 10

-- Geometry
local FRAME_W     = 320
local PAD_L       = 14   -- 1px border + 3px accent strip + 10px
local PAD_R       = 10
local PAD_TOP     = 10
local CONTENT_W   = FRAME_W - PAD_L - PAD_R
local BODY_TOP    = 32   -- first body row, below the header row
local BAR_H       = 10
local BOTTOM_PAD  = BAR_H + 8  -- clears the bottom bar (plus its 1px border) with breathing room
local BTN_H       = 22
local BTN_GAP     = 8
local BTN_ROW_GAP = 6
-- Rapid buttons in two rows on one 3-column grid: widths + 2 gaps = CONTENT_W (296).
--   top row    -10 | +10 | >> T-Ns
--   bottom row Defer | Restart | End Rapid
local BTN_COLS    = { 93, 94, 93 }
-- Post-wipe prompt: Start Rapid | Dismiss; widths + 1 gap = CONTENT_W (296)
local PROMPT_BTN_WIDTHS = { 144, 144 }
local MIN_LINE_H  = 12
local SLIM_H      = 30   -- in-combat strip: header row only
local SLIM_ALPHA  = 0.55

-- Default spot when no overlay / ready-check frame is up: the frame's TOP this far
-- below the screen centre (UIParent units), below the play area's middle.
local DEFAULT_Y   = -160

local FADE_IN  = 0.15
local FADE_OUT = 0.25

local STEP_LABELS = { "RC Sent", "Waiting", "Result", "Pull Timer" }

local RAPID_ICON = "|TInterface\\Icons\\ability_hunter_efficiency:12:12:0:0:64:64:5:59:5:59|t "
local MODE_TEXT = {
    rc    = "READY CHECK",
    pull  = "PULL TIMER",
    rapid = RAPID_ICON .. "RAPID MODE",
}

-- Close glyph: grey (desaturated) X, as in Blizzard_FriendsFrame/Mainline/FriendsFrame.xml.
local CLOSE_ATLAS = "groupfinder-icon-redx"

-- Rapid mode UI state
local rapidModeActive = false
-- Remaining seconds at which PT sends this cycle's ready check (RAPID_COUNTDOWN_START
-- rcAt); nil when it is sent at once or already out, so no "Ready check in" line shows.
local rapidRCAt = nil
-- True from RAPID_COMBAT_START until the next countdown (or the session) begins.
local rapidInCombat = false
-- Slim in-combat strip is showing (rapid mode only).
local slim = false
-- Post-wipe "Start Rapid" prompt is showing (never together with rapid mode).
local promptActive = false

-- Hide bookkeeping. `hiding` = a fade-out is in flight (the frame still reports
-- IsShown()); `resetOnHide` = restore the idle look once the fade completes.
local hiding = false
local resetOnHide = false

-- Preview (Addon.PreviewPullFrame) state
local preview = { active = false, timers = {} }

-- Debug helper
local function Debug(msg)
    if _G.RCPT_Debug then _G.RCPT_Debug(msg) end
end

local function Print(msg)
    if Addon and Addon.Print then Addon.Print(msg) else print("[RCPT] " .. tostring(msg)) end
end

local function GetStyle()
    return Addon and Addon.Style
end

-- DB alias
local function GetDB()
    return (_G.RCPT and _G.RCPT.db) or RCPT_Config or {}
end

-- Shared frame scale (RCPT_Config.frameScale, 0.75-1.5); falls back to 1 until the
-- setting exists, so load order never matters.
local function FrameScale()
    local cfg = (type(RCPT_Config) == "table" and RCPT_Config) or GetDB()
    local s = tonumber(cfg.frameScale) or 1
    if s ~= s or s < 0.5 then s = 0.5 elseif s > 2 then s = 2 end
    return s
end

-- True while the frame is up, not on its way out and not just showing the
-- post-wipe prompt (the prompt is not a sequence; real callbacks replace it).
local function IsActive()
    return frame ~= nil and frame:IsShown() and not hiding and not promptActive
end

-- Format seconds into "M:SS" or "Ns"
local function FormatTime(seconds)
    seconds = seconds or 0
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
    end
    return tostring(seconds) .. "s"
end

-- Plain "77s" (no M:SS), matching the scanner's "Ascendance 72s" in reason lines.
local function Secs(seconds)
    return tostring(math.floor((tonumber(seconds) or 0) + 0.5)) .. "s"
end

local function Colorize(token, text)
    local Style = GetStyle()
    if Style then return Style.Colorize(token, text) end
    return tostring(text or "")
end

-- Return a "|cAARRGGBB" prefix for a class file token (e.g. "WARRIOR").
local function ClassColorCode(class)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        if c.colorStr then return "|c" .. c.colorStr end
        return string.format("|cff%02x%02x%02x",
            math.floor((c.r or 1) * 255),
            math.floor((c.g or 1) * 255),
            math.floor((c.b or 1) * 255))
    end
    local Style = GetStyle()
    return "|c" .. (Style and Style.Hex("textDim") or "ffaaaaaa")
end

-- Not-ready list for the ephemeral row: one class-coloured name per line with a
-- status atlas (decline = said no, pending = no response), capped at
-- NOTREADY_LINE_CAP lines plus a "+N more" line.
local function FormatNotReadyList(list)
    if not list or #list == 0 then return "" end
    local Style = GetStyle()
    local lines = {}
    local shown = math.min(NOTREADY_LINE_CAP, #list)
    for i = 1, shown do
        local p = list[i]
        local declined = (p.reason == "no")
        local icon = Style and Style.StatusIcon(declined and "notready" or "waiting", 12) or ""
        local note = declined and Colorize("fail", "declined") or Colorize("textDim", "no response")
        lines[#lines + 1] = icon .. " " .. ClassColorCode(p.class) .. (p.name or "?") .. "|r  " .. note
    end
    if #list > shown then
        lines[#lines + 1] = Colorize("textDim", string.format("+%d more", #list - shown))
    end
    return table.concat(lines, "\n")
end

local function ReadyCount(confirmed, tracked)
    return string.format("%d/%d", confirmed or 0, tracked or 0)
end

---------------------------------------------------------------------------
-- Timer management: cancel helpers
---------------------------------------------------------------------------
local function CancelRetryTicker()
    if retryTicker then
        pcall(function() retryTicker:Cancel() end)
        retryTicker = nil
    end
end

local function CancelPullTicker()
    if pullTicker then
        pcall(function() pullTicker:Cancel() end)
        pullTicker = nil
    end
end

local function CancelAutoHide()
    if autoHideTicker then
        pcall(function() autoHideTicker:Cancel() end)
        autoHideTicker = nil
    end
end

local function CancelNotReadyTicker()
    if notReadyTicker then
        pcall(function() notReadyTicker:Cancel() end)
        notReadyTicker = nil
    end
end

local function CancelPromptTimer()
    if promptTimer then
        pcall(function() promptTimer:Cancel() end)
        promptTimer = nil
    end
end

-- Stops the reason line's pulse (and its end timer); alpha falls back to 1.
local function CancelReasonPulse()
    if reasonPulseTimer then
        pcall(function() reasonPulseTimer:Cancel() end)
        reasonPulseTimer = nil
    end
    local Style = GetStyle()
    if Style and ui.reason then Style.StopPulse(ui.reason) end
end

local function CancelAllTimers()
    CancelRetryTicker()
    CancelPullTicker()
    CancelAutoHide()
    CancelNotReadyTicker()
    CancelPromptTimer()
    CancelReasonPulse()
end

---------------------------------------------------------------------------
-- Visual primitives (all no-ops until the frame exists)
---------------------------------------------------------------------------

-- State colour for accent strip, countdown and bar: "accent" | "wait" | "ready" | "fail" | "idle".
local function SetTone(token)
    local Style = GetStyle()
    if not frame or not Style then return end
    frame:SetAccent(token)
    ui.countdown:SetTextColor(Style.Color(token))
    ui.bar:SetBarColor(token)
end

-- Mode label; in the slim strip it also says the frame is waiting out combat.
local function SetMode(kind)
    if not frame then return end
    ui.modeKind = kind
    local text = MODE_TEXT[kind] or ""
    if slim then text = text .. "  " .. Colorize("textDim", "in combat") end
    ui.mode:SetText(text)
end

-- Big right-aligned figure in the header (ready count or time); nil hides it.
-- The text is kept while the slim strip hides the figure.
local function SetCountdown(text)
    if not frame then return end
    ui.countdown:SetText(text or "")
    ui.countdown:SetShown(text ~= nil and not slim)
end

-- Height follows content: header + body rows + bottom padding. TOP-anchored, so a
-- taller frame grows downwards only.
local function Relayout()
    if not frame then return end
    if slim then
        frame:SetHeight(SLIM_H)
        return
    end
    local statusH = math.max(MIN_LINE_H, math.ceil(ui.status:GetStringHeight() or 0))
    local h
    if rapidModeActive or promptActive then
        h = BODY_TOP + statusH
        if ui.reason:IsShown() then
            h = h + 4 + math.max(MIN_LINE_H, math.ceil(ui.reason:GetStringHeight() or 0))
        end
        if rapidModeActive then
            if ui.notReady:IsShown() then
                h = h + 6 + math.max(MIN_LINE_H, math.ceil(ui.notReady:GetStringHeight() or 0))
            end
            h = h + 10 + BTN_H + BTN_ROW_GAP + BTN_H + BOTTOM_PAD
        else
            h = h + 10 + BTN_H + BOTTOM_PAD
        end
    else
        h = BODY_TOP + ui.stepper.height + 8 + statusH + BOTTOM_PAD
    end
    frame:SetHeight(h)
end

local function SetStatus(text)
    if not frame then return end
    ui.status:SetText(text or "")
    Relayout()
end

-- Reason line (rapid: dynamic timer; prompt: suggested timer) under the status line,
-- shown in those layouts when it has text; the not-ready list hangs below whichever
-- of the two is the lowest.
local function LayoutBodyRows()
    if not frame then return end
    local t = ui.reason:GetText()
    ui.reason:SetShown((rapidModeActive or promptActive) and not slim and t ~= nil and t ~= "")
    ui.notReady:ClearAllPoints()
    ui.notReady:SetPoint("TOPLEFT", ui.reason:IsShown() and ui.reason or ui.status, "BOTTOMLEFT", 0, -6)
end

-- Sets (nil / "" clears) the reason line; flash = pulse it briefly (extensions).
local function SetReason(text, flash)
    if not frame then return end
    CancelReasonPulse()
    ui.reason:SetText(text or "")
    LayoutBodyRows()
    Relayout()
    if flash and ui.reason:IsShown() then
        local Style = GetStyle()
        if Style then
            Style.Pulse(ui.reason)
            reasonPulseTimer = C_Timer.NewTimer(REASON_PULSE_SECONDS, function()
                reasonPulseTimer = nil
                CancelReasonPulse()
            end)
        end
    end
end

-- Progress bar: drains from full to empty over `duration` seconds from `startTime`;
-- its label shows the remaining whole seconds, after an optional prefix ("Pull in").
local barRun = { start = 0, duration = 0, prefix = nil, shown = nil }

local function BarLabel(bar, secs)
    if barRun.shown == secs then return end
    barRun.shown = secs
    local t = FormatTime(secs)
    bar:SetLabel(barRun.prefix and (barRun.prefix .. " " .. t) or t)
end

local function BarOnUpdate(self)
    local d = barRun.duration
    local left = d - (GetTime() - barRun.start)
    if left <= 0 then
        self:SetValue(0)
        BarLabel(self, 0)
        self:SetScript("OnUpdate", nil)
        return
    end
    self:SetValue(left / d)
    BarLabel(self, math.ceil(left))
end

local function StopBar()
    if not frame then return end
    ui.bar:SetScript("OnUpdate", nil)
    ui.bar:SetValue(0)
    ui.bar:SetLabel("")
    ui.bar:ClearTicks()
    barRun.shown = nil
    ui.bar:Hide()
end

-- Starts (or restarts) the bar; clears any ticks, so callers add theirs afterwards.
local function StartBar(duration, startTime, prefix)
    if not frame then return end
    if type(duration) ~= "number" or duration <= 0 then StopBar(); return end
    barRun.start = startTime or GetTime()
    barRun.duration = duration
    barRun.prefix = prefix
    barRun.shown = nil
    ui.bar:ClearTicks()
    ui.bar:SetShown(not slim)
    BarOnUpdate(ui.bar)
    if barRun.duration - (GetTime() - barRun.start) > 0 then
        ui.bar:SetScript("OnUpdate", BarOnUpdate)
    end
end

-- Rapid-mode markers on a bar spanning `duration` s: when the ready check goes out
-- (`rcAt` s remaining, nil = none to mark) and the 10 s cutoff (only while the ready
-- check has not passed).
local function AddRapidTicks(duration, rcAt, showCutoff)
    if not frame or type(duration) ~= "number" or duration <= 0 then return end
    if rcAt and rcAt > 0 and rcAt < duration then
        ui.bar:AddTick(rcAt / duration, "wait")
    end
    if showCutoff and duration > RAPID_CUTOFF_SECONDS then
        ui.bar:AddTick(RAPID_CUTOFF_SECONDS / duration, "fail")
    end
end

---------------------------------------------------------------------------
-- Stepper (status atlases come from Style's SetStep)
---------------------------------------------------------------------------
local function SetStepState(index, state)
    stepStates[index] = state
    if frame then ui.stepper:SetStep(index, state) end
end

local function ResetBreadcrumbs()
    for i = 1, #STEP_LABELS do stepStates[i] = "idle" end
    if frame then ui.stepper:Reset() end
end

local function AdvanceTo(stepIndex, state)
    -- mark all previous steps as done if they are still idle/active
    for i = 1, stepIndex - 1 do
        local cur = stepStates[i] or "idle"
        if cur == "active" or cur == "idle" then
            SetStepState(i, "done")
        end
    end
    SetStepState(stepIndex, state)
end

---------------------------------------------------------------------------
-- Mode layout
---------------------------------------------------------------------------

-- Show the widgets that belong to the current mode (normal, rapid or the slim
-- in-combat strip). Alpha and mouse are owned by SetSlim, not here.
local function ApplyMode()
    if not frame then return end
    local rapid = rapidModeActive
    local prompt = promptActive and not rapid
    ui.stepper:SetShown(not rapid and not prompt and not slim)
    ui.status:SetShown(not slim)
    ui.close:SetShown(not slim)
    for _, b in ipairs(ui.buttons) do b:SetShown(rapid and not slim) end
    for _, b in ipairs(ui.promptButtons) do b:SetShown(prompt and not slim) end
    if not rapid then
        ui.notReady:SetText("")
        ui.notReady:Hide()
    elseif slim then
        ui.notReady:Hide()
    elseif ui.notReady:GetText() and ui.notReady:GetText() ~= "" then
        ui.notReady:Show()
    end
    if slim then
        ui.countdown:Hide()
        ui.bar:Hide()
    else
        ui.countdown:SetShown((ui.countdown:GetText() or "") ~= "")
        if ui.bar:GetScript("OnUpdate") then ui.bar:Show() end
    end
    ui.status:ClearAllPoints()
    if rapid or prompt then
        ui.status:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_L, -BODY_TOP)
    else
        ui.status:SetPoint("TOPLEFT", ui.stepper, "BOTTOMLEFT", 0, -8)
    end
    LayoutBodyRows()
    SetMode(ui.modeKind)
    Relayout()
end

-- Slim strip for rapid mode in combat: header only, click-through, low alpha.
-- Only this addon's own non-secure frame is touched (no protected calls).
local function SetSlim(on)
    on = on and true or false
    if slim == on then return end
    slim = on
    if not frame then return end
    frame:EnableMouse(not on)
    frame:SetAlpha(on and SLIM_ALPHA or 1)
    ApplyMode()
end

local function ShowRapidUI()
    rapidModeActive = true
    if not frame then return end
    SetMode("rapid")
    SetTone("accent")
    ApplyMode()
end

local function HideRapidUI()
    CancelNotReadyTicker()
    rapidModeActive = false
    rapidInCombat = false
    SetSlim(false)
    if not frame then return end
    SetMode("rc")
    SetTone("idle")
    SetCountdown(nil)
    ui.status:SetText("")
    CancelReasonPulse()
    ui.reason:SetText("")
    ApplyMode()
end

-- Drops the post-wipe prompt state and its texts (the frame itself stays as it is;
-- the caller either reuses it or hides it).
local function ClearPrompt()
    CancelPromptTimer()
    if not promptActive then return end
    promptActive = false
    if not frame then return end
    CancelReasonPulse()
    ui.reason:SetText("")
    ui.status:SetText("")
    SetMode("rc")
    SetTone("idle")
    ApplyMode()
end

-- Idle look for the next show: empty stepper, no countdown, no bar.
local function ResetVisuals()
    StopBar()
    ResetBreadcrumbs()
    SetCountdown(nil)
    ClearPrompt()
    if not rapidModeActive then HideRapidUI() end
end

---------------------------------------------------------------------------
-- Frame creation (lazy)
---------------------------------------------------------------------------
local function ResolveAnchor()
    -- Priority: TalentCheck overlay > TalentCheck mini > ReadyCheckFrame > default spot
    -- Uses the shared overlay registry in RCPT core as the single source of truth.
    local RCPT = _G.RCPT
    if RCPT and RCPT.IsOverlayActive then
        if RCPT:IsOverlayActive("TalentCheckOverlay") then
            return RCPT:GetOverlayFrame("TalentCheckOverlay")
        end
        if RCPT:IsOverlayActive("TalentCheckMiniOverlay") then
            return RCPT:GetOverlayFrame("TalentCheckMiniOverlay")
        end
    end
    if ReadyCheckFrame and ReadyCheckFrame.IsShown and ReadyCheckFrame:IsShown() then
        return ReadyCheckFrame
    end
    return nil
end

-- Always TOP-anchored so the frame grows downwards only.
local function ApplyDefaultAnchor(f)
    f:ClearAllPoints()
    local anchor = ResolveAnchor()
    if anchor then
        f:SetPoint("TOP", anchor, "BOTTOM", 0, -8)
    else
        -- DEFAULT_Y is in UIParent units; SetPoint offsets are in the frame's (scaled) units.
        f:SetPoint("TOP", UIParent, "CENTER", 0, DEFAULT_Y / (f:GetScale() or 1))
    end
end

-- Saved position (DB.pullTimerPos, UIParent-relative). Style.ApplyPosition reads the
-- TOP format and older CENTER saves, re-anchoring both by TOP. Invalid or off-screen
-- -> default anchor.
local function ApplySavedOrDefault(f)
    local Style = GetStyle()
    local saved = GetDB().pullTimerPos
    if saved ~= nil and Style then
        local ok, applied = pcall(Style.ApplyPosition, f, saved)
        if ok and applied then
            -- Migrate an older CENTER save once, so its top edge stops depending on
            -- the frame height at show time.
            if type(saved) == "table" and saved.point ~= "TOP" then
                local pos = Style.GetPosition(f)
                if pos then GetDB().pullTimerPos = pos end
            end
            return
        end
        Debug("PullTimers UI saved position invalid or off screen, using default")
    end
    ApplyDefaultAnchor(f)
end

-- frameScale / lockFrames listener (Addon.frameSettingListeners.pull). The lock is
-- read by Style.MakeMovable at drag start, so only the scale needs applying here.
local function ApplyFrameSettings()
    if not frame then return end
    local scale = FrameScale()
    if math.abs((frame:GetScale() or 1) - scale) > 0.001 then
        frame:SetScale(scale)
        if frame:IsShown() then ApplySavedOrDefault(frame) end
    end
end

if Addon then
    Addon.frameSettingListeners = Addon.frameSettingListeners or {}
    Addon.frameSettingListeners.pull = ApplyFrameSettings
end

local StopPreview -- forward declaration (defined with the preview below)
local HidePrompt  -- forward declaration (defined after HideFrame)

-- Everything that must happen once the frame is hidden (the frame's OnHide).
local function OnFrameHidden()
    CancelAllTimers()
    StopBar()
    if preview.active then StopPreview() end
    ClearPrompt()  -- also when hidden by the close button (no reset pending)
    hiding = false
    if resetOnHide then
        resetOnHide = false
        ResetVisuals()
    end
end

-- Fade the frame out (0 = hide now). Style hides synchronously for 0 s or when the
-- fade cannot play; if OnHide did not run then (parent hidden), run its work here.
local function FadeOutFrame(seconds)
    hiding = true
    GetStyle().FadeOut(frame, seconds)
    if hiding and not frame:IsShown() then OnFrameHidden() end
end

local function UpdateRapidButtons(state)
    if not frame then return end
    local b = ui.buttons
    -- -10 / +10 follow Skip, except while deferred: Adjust needs a running countdown.
    local counting = (state == "COUNTDOWN" or state == "RC_PENDING")
    if counting then
        b.defer:Enable()
        b.restart:Disable()
        b.skip:Enable()
    elseif state == "DEFERRED" then
        b.defer:Disable()
        b.restart:Enable()
        b.skip:Enable()
    else
        b.defer:Disable()
        b.restart:Disable()
        b.skip:Disable()
    end
    b.minus:SetEnabled(counting)
    b.plus:SetEnabled(counting)
end

local function SkipSeconds()
    return GetDB().rapidModeSkipTo or 30
end

local function SkipLabel()
    return ">> T-" .. SkipSeconds() .. "s"
end

-- Button click handlers; inert while the preview runs.
local function RapidAction(globalName)
    return function()
        if preview.active then return end
        local fn = _G[globalName]
        if fn then fn() end
    end
end

-- -10 / +10: move the running countdown; a refusal is printed (inert in the preview).
local function AdjustAction(delta)
    return function()
        if preview.active then return end
        local fn = _G.RCPT_RapidMode_Adjust
        if type(fn) ~= "function" then return end
        local ok, reason = fn(delta)
        if not ok then Print("Not adjusted: " .. tostring(reason or "unknown reason.")) end
    end
end

-- Prompt "Start Rapid": starts a session (its callbacks replace the prompt); a
-- refusal is printed and the prompt goes away either way.
local function PromptStart()
    if preview.active then return end
    local fn = _G.RCPT_RapidMode_Start
    if type(fn) ~= "function" then
        Print("Rapid Mode is not available.")
    else
        local ok, reason = fn()
        local running = _G.RCPT_RapidMode_IsActive and _G.RCPT_RapidMode_IsActive()
        if not ok and not running then
            Print("Rapid Mode could not start: " .. tostring(reason or "unknown reason."))
        end
    end
    if promptActive then HidePrompt() end
end

local function PromptDismiss()
    if promptActive then HidePrompt() end
end

-- Tooltip bodies, read at hover time so they follow the current settings.
local TIPS = {
    defer = { "Defer pull", function()
        return "Stops this countdown and cancels the pull timer. Rapid Mode stays on: "
            .. "use Restart or Skip to continue."
    end },
    restart = { "Restart countdown", function()
        return "Starts a fresh " .. FormatTime(GetDB().rapidModeDuration or 90)
            .. " countdown after a deferred or canceled pull."
    end },
    skip = { "Skip ahead", function()
        local n = SkipSeconds()
        return "Jumps the countdown to " .. n .. " seconds (the Rapid Mode skip setting). "
            .. "A ready check that already passed is kept. While deferred, starts a "
            .. n .. "-second cycle with an immediate ready check."
    end },
    stop = { "End Rapid Mode", function()
        return "Ends the Rapid Mode session and cancels a running countdown."
    end },
    minus = { "10 seconds less", function()
        return "Takes 10 seconds off the running countdown (not below 15 seconds). "
            .. "The ready-check state is kept."
    end },
    plus = { "10 seconds more", function()
        return "Adds 10 seconds to the running countdown (up to 6:00), for example while "
            .. "someone waits for a cooldown. The ready-check state is kept."
    end },
    promptStart = { "Start Rapid Mode", function()
        return "Starts a Rapid Mode session now: a countdown with an automatic ready check "
            .. "before every pull, restarted after each wipe. End it with End Rapid or /rcpt rapid."
    end },
    promptDismiss = { "Dismiss", function()
        return "Hides this prompt. You can start Rapid Mode later with /rcpt rapid."
    end },
    close = { "Hide", function()
        return "Hides this frame. A running pull timer or Rapid Mode session continues; "
            .. "the frame comes back with the next ready check or countdown."
    end },
}

local function CreateStatusFrame()
    if frame then return frame end
    local Style = GetStyle()
    if not Style then
        Debug("PullTimers UI: RCPT Style is not available")
        return nil
    end

    local f = Style.CreatePanel(FRAME_NAME, UIParent, { width = FRAME_W, strata = "HIGH", accent = "left" })
    f:SetSize(FRAME_W, 82)
    f:SetClampedToScreen(true)
    frame = f

    -- Drag refused while lockFrames is on (checked by Style at drag start).
    Style.MakeMovable(f, function(self)
        local pos = Style.GetPosition(self)
        if pos then GetDB().pullTimerPos = pos end
    end)

    -- Header row --------------------------------------------------------
    ui.brand = Style.CreateText(f, "small", "accent")
    ui.brand:SetPoint("TOPLEFT", f, "TOPLEFT", PAD_L, -PAD_TOP)
    ui.brand:SetText("RCPT")

    ui.mode = Style.CreateText(f, "small", "textDim")
    ui.mode:SetPoint("LEFT", ui.brand, "RIGHT", 8, 0)
    ui.mode:SetJustifyH("LEFT")

    ui.close = Style.CreateButton(f, "", { width = 18, height = 18, variant = "ghost" })
    ui.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    do
        local hasAtlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(CLOSE_ATLAS)
        if hasAtlas then
            local icon = ui.close:CreateTexture(nil, "ARTWORK")
            icon:SetSize(10, 10)
            icon:SetPoint("CENTER", 0, 0)
            icon:SetAtlas(CLOSE_ATLAS)
            icon:SetDesaturated(true)
            icon:SetVertexColor(Style.Color("textDim"))
            ui.close.icon = icon
        else
            ui.close:SetText("x")
        end
    end
    ui.close:SetScript("OnClick", function()
        -- Hides the frame only; OnHide cancels the display timers as before.
        if frame and frame:IsShown() then
            FadeOutFrame(FADE_OUT)
        end
    end)
    Style.SetTooltip(ui.close, TIPS.close[1], TIPS.close[2])

    ui.countdown = Style.CreateText(f, "huge", "text")
    ui.countdown:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -7)
    ui.countdown:SetJustifyH("RIGHT")
    ui.countdown:Hide()

    -- Normal mode body ----------------------------------------------------
    ui.stepper = Style.CreateStepper(f, STEP_LABELS, { width = CONTENT_W })
    ui.stepper:SetPoint("TOPLEFT", f, "TOPLEFT", PAD_L, -BODY_TOP)

    ui.status = Style.CreateText(f, "body", "text")
    ui.status:SetWidth(CONTENT_W)
    ui.status:SetJustifyH("LEFT")
    ui.status:SetWordWrap(true)
    ui.status:SetText("")

    -- Rapid mode / prompt body ------------------------------------------------
    -- Reason line: why the countdown is longer (dynamic timer) or the suggested timer.
    ui.reason = Style.CreateText(f, "small", "textDim")
    ui.reason:SetPoint("TOPLEFT", ui.status, "BOTTOMLEFT", 0, -4)
    ui.reason:SetWidth(CONTENT_W)
    ui.reason:SetJustifyH("LEFT")
    ui.reason:SetWordWrap(true)
    ui.reason:SetText("")
    ui.reason:Hide()

    -- Ephemeral list: who held up / canceled the last pull, one name per line.
    -- Anchored below the status or the reason line by LayoutBodyRows.
    ui.notReady = Style.CreateText(f, "small", "textDim")
    ui.notReady:SetPoint("TOPLEFT", ui.status, "BOTTOMLEFT", 0, -6)
    ui.notReady:SetWidth(CONTENT_W)
    ui.notReady:SetJustifyH("LEFT")
    ui.notReady:SetWordWrap(true)
    ui.notReady:SetSpacing(2)
    ui.notReady:SetText("")
    ui.notReady:Hide()

    -- widths: one entry per column; row 1 = bottom row, row 2 sits above it.
    local function MakeButton(widths, row, col, key, text, variant, onClick)
        local x = PAD_L
        for i = 1, col - 1 do x = x + widths[i] + BTN_GAP end
        local y = BOTTOM_PAD + (row - 1) * (BTN_H + BTN_ROW_GAP)
        local b = Style.CreateButton(f, text, { width = widths[col], height = BTN_H, variant = variant })
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, y)
        b:SetScript("OnClick", onClick)
        Style.SetTooltip(b, TIPS[key][1], TIPS[key][2])
        b:Hide()
        return b
    end
    local buttons = {
        minus   = MakeButton(BTN_COLS, 2, 1, "minus", "-10", "default", AdjustAction(-10)),
        plus    = MakeButton(BTN_COLS, 2, 2, "plus", "+10", "default", AdjustAction(10)),
        skip    = MakeButton(BTN_COLS, 2, 3, "skip", SkipLabel(), "primary", RapidAction("RCPT_RapidMode_Skip")),
        defer   = MakeButton(BTN_COLS, 1, 1, "defer", "Defer", "default", RapidAction("RCPT_RapidMode_Defer")),
        restart = MakeButton(BTN_COLS, 1, 2, "restart", "Restart", "default", RapidAction("RCPT_RapidMode_Restart")),
        stop    = MakeButton(BTN_COLS, 1, 3, "stop", "End Rapid", "danger", RapidAction("RCPT_RapidMode_Stop")),
    }
    -- array part for iteration, named part for the enable rules
    buttons[1], buttons[2], buttons[3] = buttons.minus, buttons.plus, buttons.skip
    buttons[4], buttons[5], buttons[6] = buttons.defer, buttons.restart, buttons.stop
    ui.buttons = buttons

    -- Post-wipe prompt buttons (one row)
    local promptButtons = {
        start   = MakeButton(PROMPT_BTN_WIDTHS, 1, 1, "promptStart", "Start Rapid", "primary", PromptStart),
        dismiss = MakeButton(PROMPT_BTN_WIDTHS, 1, 2, "promptDismiss", "Dismiss", "ghost", PromptDismiss),
    }
    promptButtons[1], promptButtons[2] = promptButtons.start, promptButtons.dismiss
    ui.promptButtons = promptButtons

    -- Progress bar, flush along the bottom edge inside the border ----------------
    -- (x = 5 keeps the bar's 1px outer border clear of the 3px accent strip)
    ui.bar = Style.CreateBar(f, { width = FRAME_W - 6, height = BAR_H })
    ui.bar:ClearAllPoints()
    ui.bar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 5, 1)
    ui.bar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    ui.bar:Hide()

    -- Combat: normal mode hides at once; rapid mode shrinks to the slim strip
    -- (RAPID_COMBAT_START) and is restored here when combat ends.
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_ENABLED" then
            if slim then
                SetSlim(false)
                if rapidInCombat and rapidModeActive then
                    SetCountdown("--")
                    SetStatus("Combat ended")
                end
            end
            return
        end
        if event ~= "PLAYER_REGEN_DISABLED" then return end
        if preview.active then
            StopPreview()
        elseif rapidModeActive then
            -- Rapid mode handles combat itself (RAPID_COMBAT_START); don't hide
            return
        end
        CancelAllTimers()
        ResetBreadcrumbs()
        if self:IsShown() then
            resetOnHide = true
            FadeOutFrame(0)  -- immediate, also cancels a fade-out in flight
        else
            ResetVisuals()
        end
        Debug("PullTimers UI hidden due to combat")
    end)

    -- HookScript, not SetScript: SetScript would drop the OnHide hook Style.MakeMovable set.
    f:HookScript("OnHide", OnFrameHidden)

    ApplyFrameSettings()
    ResetBreadcrumbs()
    SetMode("rc")
    SetTone("idle")
    ApplyMode()
    f:Hide()
    return f
end

---------------------------------------------------------------------------
-- Show/hide helpers
---------------------------------------------------------------------------

-- Returns the frame, or nil when it cannot be built.
local function ShowFrame()
    local f = CreateStatusFrame()
    if not f then return nil end
    if resetOnHide then
        -- A fade-out was still running; finish its reset before reuse.
        resetOnHide = false
        ResetVisuals()
    end
    hiding = false
    ApplyFrameSettings()
    ApplyMode()
    ApplySavedOrDefault(f)
    GetStyle().FadeIn(f, FADE_IN)
    return f
end

-- Fade out (default 0.25s; 0 = immediately) and reset the look once hidden.
local function HideFrame(seconds)
    if not frame then return end
    CancelAllTimers()
    if frame:IsShown() then
        resetOnHide = true
        FadeOutFrame(seconds or FADE_OUT)
    else
        ResetVisuals()
    end
end

local function AutoHideAfter(seconds)
    CancelAutoHide()
    autoHideTicker = C_Timer.NewTimer(seconds, function()
        autoHideTicker = nil
        HideFrame()
    end)
end

-- Fades the post-wipe prompt out; the reset once hidden clears its state.
HidePrompt = function(seconds)
    CancelPromptTimer()
    if frame and frame:IsShown() then
        HideFrame(seconds)
    else
        ClearPrompt()
    end
end

---------------------------------------------------------------------------
-- Rapid mode UI helpers
---------------------------------------------------------------------------
-- Show / hide the ephemeral not-ready list; the panel height follows it and the
-- buttons, anchored to the bottom edge, move with it.
local function ShowNotReadyRow(text)
    if not frame then return end
    ui.notReady:SetText(text or "")
    ui.notReady:SetShown(not slim)
    Relayout()
end

local function HideNotReadyRow()
    CancelNotReadyTicker()
    if not frame then return end
    ui.notReady:SetText("")
    ui.notReady:Hide()
    Relayout()
end

local function ScheduleNotReadyAutoHide()
    CancelNotReadyTicker()
    notReadyTicker = C_Timer.NewTimer(NOTREADY_DISPLAY_SECONDS, function()
        notReadyTicker = nil
        HideNotReadyRow()
    end)
end

---------------------------------------------------------------------------
-- Rapid mode callback handlers
---------------------------------------------------------------------------
local function OnRapidSessionStart(_, payload)
    ClearPrompt()  -- a session replaces the post-wipe prompt
    if not ShowFrame() then return end
    rapidInCombat = false
    -- Still in combat (trash, adds): stay click-through until PLAYER_REGEN_ENABLED.
    SetSlim(InCombatLockdown() and true or false)
    ShowRapidUI()
    HideNotReadyRow()  -- fresh session: drop any leftover ephemeral from the previous one
    -- Refresh skip button label from current config
    ui.buttons.skip:SetText(SkipLabel())
    SetCountdown(FormatTime(payload and payload.duration or 90))
    SetStatus("Starting countdown...")
    UpdateRapidButtons("COUNTDOWN")
end

local function OnRapidSessionStop()
    CancelNotReadyTicker()
    rapidModeActive = false
    rapidInCombat = false
    if frame and frame:IsShown() then
        -- Keep the rapid layout during the fade; OnHide restores the normal one.
        HideFrame()
    else
        HideRapidUI()
        HideFrame()
    end
end

-- Reason line for a countdown start: "Longest cooldown: Thrall: Ascendance 72s  ->  77s".
local function DynamicReasonText(payload, duration)
    if not (payload and payload.dynamic) then return nil end
    local reason = payload.reason
    if type(reason) == "string" and reason ~= "" then
        return "Longest cooldown: " .. reason .. "  ->  " .. Secs(duration)
    end
    return "Dynamic timer: " .. Secs(payload.base or duration) .. "  ->  " .. Secs(duration)
end

local function OnRapidCountdownStart(_, payload)
    ClearPrompt()
    if not IsActive() then
        if not ShowFrame() then return end
    end
    rapidInCombat = false
    -- Countdown restarted while still in combat: keep the click-through strip;
    -- PLAYER_REGEN_ENABLED restores the full frame (countdown text is kept).
    SetSlim(InCombatLockdown() and true or false)
    ShowRapidUI()
    HideNotReadyRow()  -- clear previous cycle's offenders before the new countdown
    local duration = payload and payload.duration or 90
    rapidRCAt = payload and payload.rcAt
    if rapidRCAt and rapidRCAt >= duration then rapidRCAt = nil end  -- sent at once
    SetCountdown(FormatTime(duration))
    SetReason(DynamicReasonText(payload, duration))  -- hidden when not dynamic
    SetStatus("Countdown active")
    StartBar(duration, nil, "Pull in")  -- clears the previous cycle's ticks
    AddRapidTicks(duration, rapidRCAt, true)
    UpdateRapidButtons("COUNTDOWN")
end

-- The running cycle moved to `remaining` (Skip, -10 / +10, or an automatic extension
-- for a late cooldown report, which carries `reason`); the ready-check state is kept.
-- The bar is re-spanned to the new remaining, so a lengthened countdown starts full.
local function OnRapidSkipped(_, payload)
    if not IsActive() then return end
    payload = payload or {}
    local remaining = tonumber(payload.remaining) or 0
    local passed = payload.rcPassed
    -- rcAt is only sent while the RC is still to go out; at or above the new remaining
    -- it goes out on the next tick, so there is nothing to mark or count down to.
    local rcAt = tonumber(payload.rcAt)
    if payload.rcSent or (rcAt and rcAt >= remaining) then rcAt = nil end
    rapidRCAt = rcAt
    SetCountdown(FormatTime(remaining))
    -- New bar span: the old ticks are cleared; the cutoff still applies until the RC passes.
    StartBar(remaining, nil, "Pull in")
    AddRapidTicks(remaining, rcAt, not passed)
    if type(payload.reason) == "string" and payload.reason ~= "" then
        SetReason("Extended for " .. payload.reason .. "  ->  " .. Secs(remaining), true)
    end
    if passed then
        SetTone("ready")
        SetStatus(Colorize("ready", "All ready!") .. " Pull incoming...")
    elseif payload.rcSent then
        -- Still pending: keep the current waiting / not-ready status text
        SetTone("wait")
    elseif rcAt then
        SetTone("accent")
        SetStatus("Ready check in " .. (remaining - rcAt) .. "s")
    else
        SetStatus("Sending ready check...")
    end
end

local function OnRapidTick(_, payload)
    if not IsActive() then return end
    local remaining = payload and payload.remaining or 0
    SetCountdown(FormatTime(remaining))
    local state = payload and payload.state or ""
    if state == "COUNTDOWN" and remaining > 0 and rapidRCAt then
        local rcIn = remaining - rapidRCAt
        if rcIn > 0 then
            SetStatus("Ready check in " .. rcIn .. "s")
        end
    end
end

local function OnRapidRCAutoSent()
    if not IsActive() then return end
    SetTone("wait")
    SetStatus("Ready check sent, waiting...")
    UpdateRapidButtons("RC_PENDING")
end

local function OnRapidRCPassed()
    if not IsActive() then return end
    SetTone("ready")
    SetStatus(Colorize("ready", "All ready!") .. " Pull incoming...")
end

local function OnRapidRCFailed(_, payload)
    if not IsActive() then return end
    local notReady = payload and payload.notReadyCount or 0
    local tracked = payload and payload.trackedCount or 0
    SetTone("wait")
    SetStatus(Colorize("fail", string.format("%d/%d not ready", notReady, tracked)) .. " - cutoff at 10s")
    local list = payload and payload.notReady
    if list and #list > 0 then
        ShowNotReadyRow(FormatNotReadyList(list))
        ScheduleNotReadyAutoHide()
    end
end

local function OnRapidCutoffCancel(_, payload)
    if not IsActive() then return end
    StopBar()
    SetTone("fail")
    SetCountdown("--")
    SetStatus(Colorize("fail", "Pull canceled") .. " - not everyone ready")
    UpdateRapidButtons("DEFERRED")
    local list = payload and payload.notReady
    if list and #list > 0 then
        ShowNotReadyRow(FormatNotReadyList(list))
        ScheduleNotReadyAutoHide()
    end
end

local function OnRapidDeferred()
    if not IsActive() then return end
    StopBar()
    SetTone("idle")
    SetCountdown("--")
    SetStatus("Pull deferred")
    UpdateRapidButtons("DEFERRED")
end

local function OnRapidPullComplete()
    if not IsActive() then return end
    StopBar()
    SetTone("ready")
    SetCountdown("0")
    SetStatus(Colorize("ready", "Pulling!"))
end

-- Fight is on: shrink to the slim strip; PLAYER_REGEN_ENABLED or the next
-- countdown restores the full frame.
local function OnRapidCombatStart()
    if not frame then return end
    rapidInCombat = true
    CancelNotReadyTicker()
    StopBar()
    SetTone("ready")
    SetCountdown("--")
    ui.notReady:SetText("")
    CancelReasonPulse()
    ui.reason:SetText("")  -- the next countdown sets its own reason line
    SetStatus("In combat...")
    UpdateRapidButtons("IN_COMBAT")
    SetSlim(true)
end

-- Post-wipe offer (PT fires it outside a session, for a leader / assistant).
-- Shown only when no sequence or session is showing; endedPreview = this callback
-- just ended a running preview (as every real callback does), so the frame that is
-- still up is free to use.
local function OnRapidWipePrompt(payload, endedPreview)
    if rapidModeActive then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if IsActive() and not endedPreview then return end
    if not ShowFrame() then return end
    CancelAllTimers()
    StopBar()
    ResetBreadcrumbs()
    promptActive = true
    SetMode("rapid")
    SetTone("accent")
    SetCountdown(nil)
    ui.status:SetText("Wipe - chain pulls with Rapid Mode?")
    local line = "Suggested timer: " .. Secs(payload and payload.suggested or GetDB().rapidModeDuration or 90)
    local reason = payload and payload.reason
    if type(reason) == "string" and reason ~= "" then line = line .. " (" .. reason .. ")" end
    ui.reason:SetText(line)
    ApplyMode()
    promptTimer = C_Timer.NewTimer(PROMPT_SECONDS, function()
        promptTimer = nil
        if promptActive then HidePrompt() end
    end)
end

---------------------------------------------------------------------------
-- Callback handlers (normal mode)
---------------------------------------------------------------------------
-- The header shows the ready count while a ready check is out; the status line
-- says what is happening, without repeating the figure.
local function OnRCSent(_, payload)
    if rapidModeActive then return end
    local DB = GetDB()
    if not DB.enableAutoPullTimers then
        -- A ready check went out without a sequence to show: the prompt is moot.
        if promptActive then HidePrompt() end
        return
    end

    ClearPrompt()  -- a real sequence replaces the post-wipe prompt
    CancelAllTimers()
    ResetBreadcrumbs()
    if not ShowFrame() then return end
    StopBar()
    SetMode("rc")
    SetTone("wait")

    AdvanceTo(1, "done")
    AdvanceTo(2, "active")

    local retryNum  = payload and payload.retryNum or 0
    local tracked   = payload and payload.trackedCount or 0
    local confirmed = payload and payload.confirmedCount or 0

    SetCountdown(ReadyCount(confirmed, tracked))
    if retryNum > 0 then
        SetStatus("Ready check sent (retry " .. retryNum .. "/" .. (payload.maxRetries or 0) .. ")")
    else
        SetStatus("Waiting for responses")
    end
end

local function OnRCConfirm(_, payload)
    if rapidModeActive then
        -- Update rapid mode status with confirm count
        if IsActive() then
            local confirmed = payload and payload.confirmedCount or 0
            local tracked = payload and payload.trackedCount or 0
            SetStatus(string.format("Waiting (%d/%d ready)", confirmed, tracked))
        end
        return
    end
    if not IsActive() then return end
    local confirmed = payload and payload.confirmedCount or 0
    local tracked   = payload and payload.trackedCount or 0
    SetCountdown(ReadyCount(confirmed, tracked))
end

local function OnRCAllReady(_, payload)
    if rapidModeActive then return end
    if not IsActive() then return end
    local tracked = payload and payload.trackedCount
    if tracked then SetCountdown(ReadyCount(tracked, tracked)) end
    AdvanceTo(3, "done")
    SetTone("ready")
    SetStatus("All ready!")
end

local function OnRCFailedRetry(_, payload)
    if rapidModeActive then return end
    if not IsActive() then return end
    local notReady     = payload and payload.notReadyCount or 0
    local tracked      = payload and payload.trackedCount or 0
    local retryNum     = payload and payload.retryNum or 0
    local maxRetries   = payload and payload.maxRetries or 0
    local retryTimeout = payload and payload.retryTimeout or 0

    AdvanceTo(3, "fail")
    SetTone("wait")
    SetStatus(string.format("%d of %d not ready - retry %d/%d", notReady, tracked, retryNum, maxRetries))

    -- Countdown ticker: header figure counts down until the retry fires
    CancelRetryTicker()
    local remaining = retryTimeout
    local function UpdateRetryText()
        if not IsActive() then CancelRetryTicker(); return end
        SetCountdown(FormatTime(remaining))
    end
    UpdateRetryText()
    StartBar(retryTimeout, nil, "Retry in")

    retryTicker = C_Timer.NewTicker(1, function()
        remaining = remaining - 1
        if remaining <= 0 then
            CancelRetryTicker()
            -- The RC_SENT callback from the retry will update the UI
            return
        end
        UpdateRetryText()
    end, retryTimeout)
end

local function OnRCFailedFinal(_, payload)
    if rapidModeActive then return end
    if not IsActive() then return end
    CancelRetryTicker()
    StopBar()
    local notReady = payload and payload.notReadyCount or 0
    local tracked  = payload and payload.trackedCount or 0
    SetCountdown(ReadyCount(math.max(0, tracked - notReady), tracked))

    AdvanceTo(3, "fail")
    SetTone("fail")
    SetStatus(string.format("%d of %d not ready. Max retries reached.", notReady, tracked))
    AutoHideAfter(5)
end

-- Pull countdown display (shared by PULL_STARTED and the preview): the header
-- figure and bar carry the time, the status line the phase.
local function RunPullCountdown(duration)
    SetMode("pull")
    SetTone("ready")
    AdvanceTo(4, "active")
    CancelPullTicker()
    SetStatus("Pull timer running")

    local remaining = duration
    local function UpdatePullText()
        if not IsActive() then CancelPullTicker(); return end
        SetCountdown(FormatTime(remaining))
    end
    UpdatePullText()
    StartBar(duration, nil, "Pull in")

    pullTicker = C_Timer.NewTicker(1, function()
        remaining = remaining - 1
        if remaining <= 0 then
            CancelPullTicker()
            if IsActive() then
                AdvanceTo(4, "done")
                StopBar()
                SetCountdown(nil)
                SetStatus("Pulling!")
            end
            return
        end
        UpdatePullText()
    end, duration)
end

local function OnPullStarted(_, payload)
    if rapidModeActive then return end
    if not IsActive() then return end
    RunPullCountdown(payload and payload.duration or 0)
end

local function OnPullCancelled()
    if rapidModeActive then return end
    if not IsActive() then return end
    CancelPullTicker()
    StopBar()
    SetCountdown(nil)
    SetMode("pull")
    AdvanceTo(4, "fail")
    SetTone("fail")
    SetStatus("Pull cancelled.")
    AutoHideAfter(3)
end

local function OnCycleComplete()
    if rapidModeActive or promptActive then return end
    HideFrame()
end

---------------------------------------------------------------------------
-- Preview: a self-contained visual demo. Sends nothing, needs no group.
---------------------------------------------------------------------------
local PREVIEW_NOT_READY = {
    { name = "Thrallgar", class = "SHAMAN", reason = "noresponse" },
    { name = "Jainalyn", class = "MAGE", reason = "no" },
    { name = "Uthermont-Silvermoon", class = "PALADIN", reason = "noresponse" },
    { name = "Sylvanyx", class = "HUNTER", reason = "no" },
    { name = "Anduinne", class = "PRIEST", reason = "noresponse" },
    { name = "Garroshk", class = "WARRIOR", reason = "noresponse" },
    { name = "Valeerah", class = "ROGUE", reason = "no" },
}

local PREVIEW_CAPTION = "Rapid Mode preview - start it with /rcpt rapid"

local function PreviewAfter(seconds, fn)
    local t = C_Timer.NewTimer(seconds, function()
        if preview.active then fn() end
    end)
    table.insert(preview.timers, t)
end

-- Status line plus the preview caption, so a viewer knows what the rapid part is.
local function PreviewRapidStatus(text)
    SetStatus(text .. "\n" .. Colorize("accent", PREVIEW_CAPTION))
end

-- Ends the preview and restores everything it touched (layout, texts, buttons).
StopPreview = function()
    if not preview.active then return end
    preview.active = false
    for _, t in ipairs(preview.timers) do
        pcall(function() t:Cancel() end)
    end
    preview.timers = {}
    CancelAllTimers()
    if not frame then return end
    frame:SetFrameStrata("HIGH")  -- back below the options panel (raised for the preview)
    StopBar()
    HideRapidUI()
    ResetBreadcrumbs()
    for _, b in ipairs(ui.buttons) do b:Enable() end
    ui.buttons.skip:SetText(SkipLabel())
    SetStatus("")
end

local function RunPreview()
    -- 0s: ready check sent, header shows the ready count; bar drains while waiting
    HideRapidUI()
    ResetBreadcrumbs()
    SetMode("rc")
    SetTone("wait")
    AdvanceTo(1, "done")
    AdvanceTo(2, "active")
    SetCountdown(ReadyCount(3, 5))
    SetStatus("Waiting for responses")
    StartBar(3)
    PreviewAfter(1, function() SetCountdown(ReadyCount(4, 5)) end)
    PreviewAfter(2, function() SetCountdown(ReadyCount(5, 5)) end)

    -- 3s: everyone ready
    PreviewAfter(3, function()
        StopBar()
        AdvanceTo(3, "done")
        SetTone("ready")
        SetStatus("All ready!")
    end)

    -- 4s: 5 second pull countdown (ends with "Pulling!" at 9s)
    PreviewAfter(4, function() RunPullCountdown(5) end)

    -- 10.5s: rapid layout, dynamic countdown (50 s -> 77 s for a running cooldown)
    -- with its reason line, ticks at the RC moment and the cutoff, all six buttons
    local rapidDuration = 77
    local rapidRemaining = 58
    local rcAt = 55
    PreviewAfter(10.5, function()
        CancelPullTicker()
        ShowRapidUI()
        HideNotReadyRow()
        ui.buttons.skip:SetText(SkipLabel())
        UpdateRapidButtons("COUNTDOWN")
        SetCountdown(FormatTime(rapidRemaining))
        SetReason(DynamicReasonText({ dynamic = true, base = 50,
            reason = "Thrallgar: Ascendance 72s" }, rapidDuration))
        PreviewRapidStatus("Ready check in " .. (rapidRemaining - rcAt) .. "s")
        StartBar(rapidDuration, GetTime() - (rapidDuration - rapidRemaining), "Pull in")
        AddRapidTicks(rapidDuration, rcAt, true)
    end)
    for i = 1, 2 do
        PreviewAfter(10.5 + i, function()
            local left = rapidRemaining - i
            SetCountdown(FormatTime(left))
            PreviewRapidStatus("Ready check in " .. (left - rcAt) .. "s")
        end)
    end

    -- 13.5s: a late cooldown report extends the countdown (reason line pulses, bar re-spans)
    local extended = 66
    PreviewAfter(13.5, function()
        SetCountdown(FormatTime(extended))
        SetReason("Extended for Jainalyn: Combustion 61s  ->  " .. Secs(extended), true)
        PreviewRapidStatus("Ready check in " .. (extended - rcAt) .. "s")
        StartBar(extended, nil, "Pull in")
        AddRapidTicks(extended, rcAt, true)
    end)
    for i = 1, 2 do
        PreviewAfter(13.5 + i, function()
            local left = extended - i
            SetCountdown(FormatTime(left))
            PreviewRapidStatus("Ready check in " .. (left - rcAt) .. "s")
        end)
    end

    -- 16.5s: pull canceled, not-ready list (5 names + "+2 more")
    PreviewAfter(16.5, function()
        StopBar()
        SetTone("fail")
        SetCountdown("--")
        PreviewRapidStatus(Colorize("fail", "Pull canceled") .. " - not everyone ready")
        UpdateRapidButtons("DEFERRED")
        ShowNotReadyRow(FormatNotReadyList(PREVIEW_NOT_READY))
    end)

    -- 22s: fade out; OnHide ends the preview and restores state
    PreviewAfter(22, function() HideFrame() end)
end

local function PreviewPullFrame()
    if InCombatLockdown and InCombatLockdown() then
        Print("The pull frame preview is not available in combat.")
        return
    end
    if _G.RCPT_RapidMode_IsActive and _G.RCPT_RapidMode_IsActive() then
        Print("Rapid mode is running; the pull frame preview was skipped.")
        return
    end
    if not preview.active and IsActive() then
        Print("A pull sequence is in progress; the pull frame preview was skipped.")
        return
    end
    -- A second click restarts the demo from the beginning.
    if preview.active then StopPreview() end
    ClearPrompt()  -- the preview replaces a post-wipe prompt the user chose to pass over
    CancelAllTimers()
    if not ShowFrame() then return end
    -- Above the options panel (HIGH) while the preview runs; StopPreview, which
    -- every preview exit goes through, puts it back to HIGH.
    frame:SetFrameStrata("DIALOG")
    preview.active = true
    RunPreview()
end

local function ResetPullFramePosition()
    local DB = GetDB()
    DB.pullTimerPos = nil
    if type(RCPT_Config) == "table" then RCPT_Config.pullTimerPos = nil end
    if frame then ApplyDefaultAnchor(frame) end
end

if Addon then
    Addon.PreviewPullFrame = PreviewPullFrame
    Addon.ResetPullFramePosition = ResetPullFramePosition
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

-- A real callback ends a running preview before it is handled.
local function Live(fn)
    return function(event, payload)
        if preview.active then StopPreview() end
        return fn(event, payload)
    end
end

-- Same rule for the wipe prompt; it is told whether it just ended the preview, so
-- it can take over the frame the preview leaves up.
local function LiveWipePrompt(_, payload)
    local endedPreview = preview.active
    if endedPreview then StopPreview() end
    return OnRapidWipePrompt(payload, endedPreview)
end

local EVENTS = {
    { "RC_SENT",        Live(OnRCSent) },
    { "RC_CONFIRM",     Live(OnRCConfirm) },
    { "RC_ALL_READY",   Live(OnRCAllReady) },
    { "RC_FAILED_RETRY", Live(OnRCFailedRetry) },
    { "RC_FAILED_FINAL", Live(OnRCFailedFinal) },
    { "PULL_STARTED",   Live(OnPullStarted) },
    { "PULL_CANCELLED", Live(OnPullCancelled) },
    { "CYCLE_COMPLETE", Live(OnCycleComplete) },
    -- Rapid mode events
    { "RAPID_SESSION_START",   Live(OnRapidSessionStart) },
    { "RAPID_SESSION_STOP",    Live(OnRapidSessionStop) },
    { "RAPID_COUNTDOWN_START", Live(OnRapidCountdownStart) },
    { "RAPID_TICK",            Live(OnRapidTick) },
    { "RAPID_SKIPPED",         Live(OnRapidSkipped) },
    { "RAPID_RC_AUTO_SENT",    Live(OnRapidRCAutoSent) },
    { "RAPID_RC_PASSED",       Live(OnRapidRCPassed) },
    { "RAPID_RC_FAILED",       Live(OnRapidRCFailed) },
    { "RAPID_CUTOFF_CANCEL",   Live(OnRapidCutoffCancel) },
    { "RAPID_DEFERRED",        Live(OnRapidDeferred) },
    { "RAPID_PULL_COMPLETE",   Live(OnRapidPullComplete) },
    { "RAPID_COMBAT_START",    Live(OnRapidCombatStart) },
    { "RAPID_WIPE_PROMPT",     LiveWipePrompt },
    -- ENCOUNTER_START: the prompt must not stay clickable into the next pull
    -- (PLAYER_REGEN_DISABLED already hides it through the frame's combat handler)
    { "RAPID_WIPE_PROMPT_CANCEL", function() if promptActive then HidePrompt() end end },
}

local registered = false

local function RegisterAll()
    if registered then return end
    if not _G.RCPT_PullTimers_RegisterCallback then return end
    for _, pair in ipairs(EVENTS) do
        _G.RCPT_PullTimers_RegisterCallback(pair[1], pair[2])
    end
    registered = true
end

local function UnregisterAll()
    if not registered then return end
    if not _G.RCPT_PullTimers_UnregisterCallback then return end
    for _, pair in ipairs(EVENTS) do
        _G.RCPT_PullTimers_UnregisterCallback(pair[1], pair[2])
    end
    registered = false
end

-- Initialize immediately (file loads after RCPT_PullTimers.lua via TOC order)
RegisterAll()

-- The manager re-attaches a torn-down module through _G.RCPT_Initialize; re-register
-- the UI callbacks there too, or the frame stays silent until /reload.
do
    local coreInitialize = _G.RCPT_Initialize
    if type(coreInitialize) == "function" then
        _G.RCPT_Initialize = function(...)
            coreInitialize(...)
            RegisterAll()
        end
    end
end

---------------------------------------------------------------------------
-- Teardown export (called from RCPT_PullTimers Teardown)
---------------------------------------------------------------------------
local function Teardown()
    StopPreview()
    ClearPrompt()
    CancelAllTimers()
    UnregisterAll()
    rapidModeActive = false
    if frame then
        HideRapidUI()
        ResetBreadcrumbs()
        HideFrame(0)
    end
    Debug("PullTimers UI torn down.")
end

_G.RCPT_PullTimers_UI_Teardown = Teardown
