-- RCPT_PullTimers_UI.lua
-- Automation status display for PullTimers: breadcrumb trail + live status text.
-- Driven entirely by callbacks from RCPT_PullTimers.lua; no OnUpdate polling.

local addonName = "RCPTPullStatus"
local frame       -- main status frame (lazy-created)
local steps = {}  -- breadcrumb step widgets { dot, label, line }
local statusText  -- FontString for detail text

-- Active C_Timer handles (cancelled on hide / combat)
local retryTicker
local pullTicker
local autoHideTicker

-- Colours used for breadcrumb states
local COLOR_INACTIVE = { r = 0.45, g = 0.45, b = 0.45 }
local COLOR_ACTIVE   = { r = 1,    g = 0.82, b = 0 }
local COLOR_SUCCESS  = { r = 0.1,  g = 0.9,  b = 0.1 }
local COLOR_FAIL     = { r = 1,    g = 0.15, b = 0.15 }

-- Current state (reset each cycle)
local currentStep = 0

-- Rapid mode UI state
local rapidModeActive = false

-- Debug helper
local function Debug(msg)
    if _G.RCPT_Debug then _G.RCPT_Debug(msg) end
end

-- DB alias
local function GetDB()
    return (_G.RCPT and _G.RCPT.db) or RCPT_Config or {}
end

-- Position persistence helpers
-- Stored in DB.pullTimerPos = { point, relativePoint, x, y }
-- Validated against current screen bounds on each restore.
local BOUNDS_MARGIN = 40  -- px; frame must be at least this far inside the screen

local function SavePosition(point, relativePoint, x, y)
    local DB = GetDB()
    DB.pullTimerPos = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function GetSavedPosition()
    local DB = GetDB()
    return DB.pullTimerPos  -- nil if never saved
end

-- Check that a saved anchor position would place the frame visibly on screen.
-- Works by computing where the frame's top-left corner ends up and ensuring
-- at least BOUNDS_MARGIN px of the frame is inside the viewport.
local function IsPositionOnScreen(pos, frameWidth, frameHeight)
    if not pos then return false end
    local sw = GetScreenWidth()  or 1920
    local sh = GetScreenHeight() or 1080
    local scale = UIParent:GetEffectiveScale()
    sw = sw * scale
    sh = sh * scale

    -- Resolve the anchor to an approximate screen-space origin (center of UIParent)
    -- For simplicity we compute the anchor's absolute x/y offset from screen center,
    -- then apply the saved offset.  This covers the common anchor points.
    local ax, ay = 0, 0  -- anchor origin relative to screen center
    local rp = pos.relativePoint or "CENTER"
    if rp:find("LEFT")   then ax = -(sw / 2) end
    if rp:find("RIGHT")  then ax =  (sw / 2) end
    if rp:find("TOP")    then ay =  (sh / 2) end
    if rp:find("BOTTOM") then ay = -(sh / 2) end

    -- Point on the frame itself
    local fx, fy = 0, 0
    local p = pos.point or "CENTER"
    if p:find("LEFT")   then fx = 0         elseif p:find("RIGHT")  then fx = -frameWidth  else fx = -(frameWidth / 2) end
    if p:find("TOP")    then fy = 0         elseif p:find("BOTTOM") then fy =  frameHeight else fy =  (frameHeight / 2) end

    -- Top-left of frame in screen coords (origin = screen center)
    local tlx = ax + (pos.x or 0) + fx
    local tly = ay + (pos.y or 0) + fy

    -- Convert to 0-based from bottom-left
    local screenLeft   = tlx + (sw / 2)
    local screenTop    = tly + (sh / 2)
    local screenRight  = screenLeft + frameWidth
    local screenBottom = screenTop - frameHeight

    -- Must have at least BOUNDS_MARGIN px visible on each axis
    if screenRight  < BOUNDS_MARGIN then return false end
    if screenLeft   > sw - BOUNDS_MARGIN then return false end
    if screenTop    < BOUNDS_MARGIN then return false end
    if screenBottom > sh - BOUNDS_MARGIN then return false end

    return true
end

-- Format seconds into "M:SS" or "Ns"
local function FormatTime(seconds)
    seconds = seconds or 0
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
    end
    return tostring(seconds) .. "s"
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

local function CancelAllTimers()
    CancelRetryTicker()
    CancelPullTicker()
    CancelAutoHide()
end

---------------------------------------------------------------------------
-- Breadcrumb rendering
---------------------------------------------------------------------------
local STEP_LABELS = { "RC Sent", "Waiting", "Result", "Pull Timer" }

-- Inline texture markup helpers (14x14 icons embedded in FontStrings)
local ICON_CIRCLE  = "|TInterface\\COMMON\\Indicator-Gray:14:14:0:0|t"
local ICON_CHECK   = "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:14:14:0:0|t"
local ICON_CROSS   = "|TInterface\\RAIDFRAME\\ReadyCheck-NotReady:14:14:0:0|t"
local ICON_ACTIVE  = "|TInterface\\COMMON\\Indicator-Yellow:14:14:0:0|t"

local function SetStepState(index, state)
    local s = steps[index]
    if not s then return end
    local c = COLOR_INACTIVE
    local icon = ICON_CIRCLE
    if state == "active" then
        c = COLOR_ACTIVE
        icon = ICON_ACTIVE
    elseif state == "success" then
        c = COLOR_SUCCESS
        icon = ICON_CHECK
    elseif state == "fail" then
        c = COLOR_FAIL
        icon = ICON_CROSS
    end
    s.dot:SetText(icon)
    s.label:SetTextColor(c.r, c.g, c.b)
end

local function ResetBreadcrumbs()
    for i = 1, 4 do
        SetStepState(i, "inactive")
        if steps[i] then steps[i]._state = "inactive" end
    end
    currentStep = 0
end

local function AdvanceTo(stepIndex, state)
    -- mark all previous steps as success if not already marked
    for i = 1, stepIndex - 1 do
        local s = steps[i]
        if s then
            -- only promote if currently active/inactive
            local cur = s._state or "inactive"
            if cur == "active" or cur == "inactive" then
                SetStepState(i, "success")
                s._state = "success"
            end
        end
    end
    SetStepState(stepIndex, state)
    if steps[stepIndex] then steps[stepIndex]._state = state end
    currentStep = stepIndex
end

---------------------------------------------------------------------------
-- Frame creation (lazy)
---------------------------------------------------------------------------
local function ResolveAnchor()
    -- Priority: TalentCheck overlay > TalentCheck mini > ReadyCheckFrame > UIParent center
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

local function CreateStatusFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", addonName .. "Frame", UIParent, "BackdropTemplate")
    frame:SetSize(320, 68)
    frame:SetFrameStrata("HIGH")
    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = false,
        edgeSize = 8,
    })
    frame:SetBackdropColor(0, 0, 0, 0.95)

    -- Make draggable
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self._userMoved = true
        -- Persist position to SavedVariables for cross-session restore
        local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
        SavePosition(point, relativePoint, xOfs, yOfs)
    end)
    frame:SetClampedToScreen(true)

    -- Breadcrumb row --
    local stepWidth = 70
    local startX = 14
    local dotY = -12
    local labelY = -24

    for i = 1, 4 do
        local xOff = startX + (i - 1) * stepWidth

        -- dot / icon
        local dot = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        dot:SetPoint("TOPLEFT", frame, "TOPLEFT", xOff + 10, dotY)
        dot:SetText(ICON_CIRCLE)

        -- label
        local lbl = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", frame, "TOPLEFT", xOff, labelY)
        lbl:SetText(STEP_LABELS[i])
        lbl:SetTextColor(COLOR_INACTIVE.r, COLOR_INACTIVE.g, COLOR_INACTIVE.b)

        -- connector line to next step
        local line
        if i < 4 then
            line = frame:CreateTexture(nil, "ARTWORK")
            line:SetColorTexture(0.35, 0.35, 0.35, 0.8)
            line:SetSize(stepWidth - 28, 2)
            line:SetPoint("LEFT", dot, "RIGHT", 4, 0)
        end

        steps[i] = { dot = dot, label = lbl, line = line, _state = "inactive" }
    end

    -- Status text --
    statusText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    statusText:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -40)
    statusText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -40)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(true)
    statusText:SetText("")

    -- =================================================================
    -- Rapid mode elements (hidden by default)
    -- =================================================================
    local rapidHeader = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    rapidHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -10)
    rapidHeader:SetText("|TInterface\\Icons\\ability_hunter_efficiency:14:14:0:0|t |cffffcc00RAPID MODE|r")
    rapidHeader:Hide()

    local rapidCountdown = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    rapidCountdown:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -6)
    rapidCountdown:SetTextColor(1, 0.82, 0)
    rapidCountdown:Hide()

    local rapidStatus = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    rapidStatus:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -30)
    rapidStatus:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -30)
    rapidStatus:SetJustifyH("LEFT")
    rapidStatus:Hide()

    local btnWidth, btnHeight = 68, 22

    local rapidBtnDefer = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    rapidBtnDefer:SetSize(btnWidth, btnHeight)
    rapidBtnDefer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 8)
    rapidBtnDefer:SetText("Defer")
    rapidBtnDefer:SetScript("OnClick", function()
        if _G.RCPT_RapidMode_Defer then _G.RCPT_RapidMode_Defer() end
    end)
    rapidBtnDefer:Hide()

    local rapidBtnRestart = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    rapidBtnRestart:SetSize(btnWidth, btnHeight)
    rapidBtnRestart:SetPoint("LEFT", rapidBtnDefer, "RIGHT", 4, 0)
    rapidBtnRestart:SetText("Restart")
    rapidBtnRestart:SetScript("OnClick", function()
        if _G.RCPT_RapidMode_Restart then _G.RCPT_RapidMode_Restart() end
    end)
    rapidBtnRestart:Hide()

    local DB = GetDB()
    local skipLabel = ">> T-" .. ((DB.rapidModeSkipTo or 30) + 15) .. "s"
    local rapidBtnSkip = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    rapidBtnSkip:SetSize(btnWidth + 12, btnHeight)
    rapidBtnSkip:SetPoint("LEFT", rapidBtnRestart, "RIGHT", 4, 0)
    rapidBtnSkip:SetText(skipLabel)
    rapidBtnSkip:SetScript("OnClick", function()
        if _G.RCPT_RapidMode_Skip then _G.RCPT_RapidMode_Skip() end
    end)
    rapidBtnSkip:Hide()

    local rapidBtnStop = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    rapidBtnStop:SetSize(btnWidth + 10, btnHeight)
    rapidBtnStop:SetPoint("LEFT", rapidBtnSkip, "RIGHT", 4, 0)
    rapidBtnStop:SetText("End Rapid")
    rapidBtnStop:SetScript("OnClick", function()
        if _G.RCPT_RapidMode_Stop then _G.RCPT_RapidMode_Stop() end
    end)
    rapidBtnStop:Hide()

    frame._rapid = {
        header = rapidHeader,
        countdown = rapidCountdown,
        status = rapidStatus,
        btnDefer = rapidBtnDefer,
        btnRestart = rapidBtnRestart,
        btnSkip = rapidBtnSkip,
        btnStop = rapidBtnStop,
    }

    -- Combat safety: hide immediately when combat starts
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if rapidModeActive then
                -- Rapid mode handles combat itself; don't hide
                return
            end
            CancelAllTimers()
            ResetBreadcrumbs()
            self:Hide()
            Debug("PullTimers UI hidden due to combat")
        end
    end)

    frame:SetScript("OnHide", function()
        CancelAllTimers()
    end)

    frame:Hide()
    return frame
end

---------------------------------------------------------------------------
-- Show/hide helpers
---------------------------------------------------------------------------
local function ShowFrame()
    local f = CreateStatusFrame()
    f:ClearAllPoints()

    local saved = GetSavedPosition()
    local fw = f:GetWidth()  or 320
    local fh = f:GetHeight() or 80

    if saved and IsPositionOnScreen(saved, fw, fh) then
        f:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
    else
        -- Saved position is missing or off-screen; fall back to default
        if saved then
            Debug("PullTimers UI saved position out of bounds, resetting")
        end
        local anchor = ResolveAnchor()
        if anchor then
            f:SetPoint("TOP", anchor, "BOTTOM", 0, -8)
        else
            f:SetPoint("CENTER", UIParent, "CENTER", 0, -80)
        end
    end
    f:Show()
end

local function HideFrame()
    if frame then
        CancelAllTimers()
        ResetBreadcrumbs()
        frame:Hide()
    end
end

local function AutoHideAfter(seconds)
    CancelAutoHide()
    autoHideTicker = C_Timer.NewTimer(seconds, function()
        autoHideTicker = nil
        HideFrame()
    end)
end

---------------------------------------------------------------------------
-- Rapid mode UI helpers
---------------------------------------------------------------------------
local function ShowRapidUI()
    if not frame or not frame._rapid then return end
    local r = frame._rapid
    rapidModeActive = true
    -- Hide normal breadcrumbs
    for i = 1, 4 do
        if steps[i] then
            steps[i].dot:Hide()
            steps[i].label:Hide()
            if steps[i].line then steps[i].line:Hide() end
        end
    end
    statusText:Hide()
    -- Show rapid elements
    r.header:Show()
    r.countdown:Show()
    r.status:Show()
    r.btnDefer:Show()
    r.btnRestart:Show()
    r.btnSkip:Show()
    r.btnStop:Show()
    frame:SetSize(320, 80)
end

local function HideRapidUI()
    rapidModeActive = false
    if not frame or not frame._rapid then return end
    local r = frame._rapid
    r.header:Hide()
    r.countdown:Hide()
    r.status:Hide()
    r.btnDefer:Hide()
    r.btnRestart:Hide()
    r.btnSkip:Hide()
    r.btnStop:Hide()
    -- Restore normal breadcrumbs
    for i = 1, 4 do
        if steps[i] then
            steps[i].dot:Show()
            steps[i].label:Show()
            if steps[i].line then steps[i].line:Show() end
        end
    end
    statusText:Show()
    frame:SetSize(320, 68)
end

local function UpdateRapidButtons(state)
    if not frame or not frame._rapid then return end
    local r = frame._rapid
    if state == "COUNTDOWN" or state == "RC_PENDING" then
        r.btnDefer:Enable()
        r.btnRestart:Disable()
        r.btnSkip:Enable()
    elseif state == "DEFERRED" then
        r.btnDefer:Disable()
        r.btnRestart:Enable()
        r.btnSkip:Enable()
    else
        r.btnDefer:Disable()
        r.btnRestart:Disable()
        r.btnSkip:Disable()
    end
end

---------------------------------------------------------------------------
-- Rapid mode callback handlers
---------------------------------------------------------------------------
local function OnRapidSessionStart(_, payload)
    CreateStatusFrame()
    ShowFrame()
    ShowRapidUI()
    local r = frame._rapid
    -- Refresh skip button label from current config
    local DB = GetDB()
    r.btnSkip:SetText(">> T-" .. ((DB.rapidModeSkipTo or 30) + 15).. "s")
    r.countdown:SetText(FormatTime(payload and payload.duration or 90))
    r.status:SetText("Starting countdown...")
    UpdateRapidButtons("COUNTDOWN")
end

local function OnRapidSessionStop()
    HideRapidUI()
    HideFrame()
end

local function OnRapidCountdownStart(_, payload)
    if not frame then CreateStatusFrame() end
    if not frame:IsShown() then ShowFrame() end
    ShowRapidUI()
    local r = frame._rapid
    local duration = payload and payload.duration or 90
    r.countdown:SetText(FormatTime(duration))
    r.status:SetText("Countdown active")
    UpdateRapidButtons("COUNTDOWN")
end

local function OnRapidTick(_, payload)
    if not frame or not frame:IsShown() or not frame._rapid then return end
    local r = frame._rapid
    local remaining = payload and payload.remaining or 0
    r.countdown:SetText(FormatTime(remaining))
    local state = payload and payload.state or ""
    if state == "COUNTDOWN" and remaining > 0 then
        local rcIn = remaining - 45
        if rcIn > 0 then
            r.status:SetText("Ready check in " .. rcIn .. "s")
        end
    end
end

local function OnRapidRCAutoSent()
    if not frame or not frame:IsShown() or not frame._rapid then return end
    frame._rapid.status:SetText("Ready check sent, waiting...")
    UpdateRapidButtons("RC_PENDING")
end

local function OnRapidRCPassed()
    if not frame or not frame:IsShown() or not frame._rapid then return end
    frame._rapid.status:SetText("|cff00ff00All ready!|r Pull incoming...")
end

local function OnRapidRCFailed(_, payload)
    if not frame or not frame:IsShown() or not frame._rapid then return end
    local notReady = payload and payload.notReadyCount or 0
    local tracked = payload and payload.trackedCount or 0
    frame._rapid.status:SetText(string.format("|cffff4444%d/%d not ready|r - cutoff at 10s", notReady, tracked))
end

local function OnRapidCutoffCancel()
    if not frame or not frame:IsShown() or not frame._rapid then return end
    local r = frame._rapid
    r.countdown:SetText("--")
    r.status:SetText("|cffff4444Pull canceled|r - not everyone ready")
    UpdateRapidButtons("DEFERRED")
end

local function OnRapidDeferred()
    if not frame or not frame:IsShown() or not frame._rapid then return end
    local r = frame._rapid
    r.countdown:SetText("--")
    r.status:SetText("Pull deferred")
    UpdateRapidButtons("DEFERRED")
end

local function OnRapidPullComplete()
    if not frame or not frame:IsShown() or not frame._rapid then return end
    local r = frame._rapid
    r.countdown:SetText("0")
    r.status:SetText("|cff00ff00Pulling!|r")
end

local function OnRapidCombatStart()
    if not frame or not frame._rapid then return end
    local r = frame._rapid
    r.countdown:SetText("--")
    r.status:SetText("In combat...")
    UpdateRapidButtons("IN_COMBAT")
end

---------------------------------------------------------------------------
-- Callback handlers (normal mode)
---------------------------------------------------------------------------
local function OnRCSent(_, payload)
    if rapidModeActive then return end
    local DB = GetDB()
    if not DB.enableAutoPullTimers then return end

    CancelAllTimers()
    ResetBreadcrumbs()
    ShowFrame()

    AdvanceTo(1, "success")
    AdvanceTo(2, "active")

    local retryNum  = payload and payload.retryNum or 0
    local tracked   = payload and payload.trackedCount or 0
    local confirmed = payload and payload.confirmedCount or 0

    if retryNum > 0 then
        statusText:SetText("Ready check sent (retry " .. retryNum .. "/" .. (payload.maxRetries or 0) .. ")")
    else
        statusText:SetText("Waiting for responses (" .. confirmed .. "/" .. tracked .. " ready)")
    end
end

local function OnRCConfirm(_, payload)
    if rapidModeActive then
        -- Update rapid mode status with confirm count
        if frame and frame:IsShown() and frame._rapid then
            local confirmed = payload and payload.confirmedCount or 0
            local tracked = payload and payload.trackedCount or 0
            frame._rapid.status:SetText(string.format("Waiting (%d/%d ready)", confirmed, tracked))
        end
        return
    end
    if not frame or not frame:IsShown() then return end
    local confirmed = payload and payload.confirmedCount or 0
    local tracked   = payload and payload.trackedCount or 0
    statusText:SetText("Waiting for responses (" .. confirmed .. "/" .. tracked .. " ready)")
end

local function OnRCAllReady(_, payload)
    if rapidModeActive then return end
    if not frame or not frame:IsShown() then return end
    AdvanceTo(3, "success")
    statusText:SetText("All ready!")
end

local function OnRCFailedRetry(_, payload)
    if rapidModeActive then return end
    if not frame or not frame:IsShown() then return end
    local notReady     = payload and payload.notReadyCount or 0
    local tracked      = payload and payload.trackedCount or 0
    local retryNum     = payload and payload.retryNum or 0
    local maxRetries   = payload and payload.maxRetries or 0
    local retryTimeout = payload and payload.retryTimeout or 0

    AdvanceTo(3, "fail")

    -- Countdown ticker: update text each second until the retry fires
    CancelRetryTicker()
    local remaining = retryTimeout
    local function UpdateRetryText()
        if not frame or not frame:IsShown() then CancelRetryTicker(); return end
        statusText:SetText(string.format(
            "%d of %d not ready. Retry %d/%d in %ds",
            notReady, tracked, retryNum, maxRetries, remaining
        ))
    end
    UpdateRetryText()

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
    if not frame or not frame:IsShown() then return end
    CancelRetryTicker()
    local notReady = payload and payload.notReadyCount or 0
    local tracked  = payload and payload.trackedCount or 0

    AdvanceTo(3, "fail")
    statusText:SetText(string.format("%d of %d not ready. Max retries reached.", notReady, tracked))
    AutoHideAfter(5)
end

local function OnPullStarted(_, payload)
    if rapidModeActive then return end
    if not frame or not frame:IsShown() then return end
    local duration = payload and payload.duration or 0

    AdvanceTo(4, "active")
    CancelPullTicker()

    local remaining = duration
    local function UpdatePullText()
        if not frame or not frame:IsShown() then CancelPullTicker(); return end
        statusText:SetText("Pull in " .. remaining .. "s")
    end
    UpdatePullText()

    pullTicker = C_Timer.NewTicker(1, function()
        remaining = remaining - 1
        if remaining <= 0 then
            CancelPullTicker()
            if frame and frame:IsShown() then
                AdvanceTo(4, "success")
                statusText:SetText("Pulling!")
            end
            return
        end
        UpdatePullText()
    end, duration)
end

local function OnPullCancelled()
    if rapidModeActive then return end
    if not frame or not frame:IsShown() then return end
    CancelPullTicker()
    AdvanceTo(4, "fail")
    statusText:SetText("Pull cancelled.")
    AutoHideAfter(3)
end

local function OnCycleComplete()
    if rapidModeActive then return end
    HideFrame()
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------
local EVENTS = {
    { "RC_SENT",        OnRCSent },
    { "RC_CONFIRM",     OnRCConfirm },
    { "RC_ALL_READY",   OnRCAllReady },
    { "RC_FAILED_RETRY", OnRCFailedRetry },
    { "RC_FAILED_FINAL", OnRCFailedFinal },
    { "PULL_STARTED",   OnPullStarted },
    { "PULL_CANCELLED", OnPullCancelled },
    { "CYCLE_COMPLETE", OnCycleComplete },
    -- Rapid mode events
    { "RAPID_SESSION_START",   OnRapidSessionStart },
    { "RAPID_SESSION_STOP",    OnRapidSessionStop },
    { "RAPID_COUNTDOWN_START", OnRapidCountdownStart },
    { "RAPID_TICK",            OnRapidTick },
    { "RAPID_RC_AUTO_SENT",    OnRapidRCAutoSent },
    { "RAPID_RC_PASSED",       OnRapidRCPassed },
    { "RAPID_RC_FAILED",       OnRapidRCFailed },
    { "RAPID_CUTOFF_CANCEL",   OnRapidCutoffCancel },
    { "RAPID_DEFERRED",        OnRapidDeferred },
    { "RAPID_PULL_COMPLETE",   OnRapidPullComplete },
    { "RAPID_COMBAT_START",    OnRapidCombatStart },
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

---------------------------------------------------------------------------
-- Teardown export (called from RCPT_PullTimers Teardown)
---------------------------------------------------------------------------
local function Teardown()
    CancelAllTimers()
    UnregisterAll()
    rapidModeActive = false
    if frame then
        HideRapidUI()
        ResetBreadcrumbs()
        frame:Hide()
    end
    Debug("PullTimers UI torn down.")
end

_G.RCPT_PullTimers_UI_Teardown = Teardown
