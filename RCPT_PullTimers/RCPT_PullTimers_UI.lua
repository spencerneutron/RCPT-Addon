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

-- Saved drag position (persists within session, not across reloads)
local savedPoint = nil  -- { point, relativeTo, relativePoint, x, y }

-- Debug helper
local function Debug(msg)
    if _G.RCPT_Debug then _G.RCPT_Debug(msg) end
end

-- DB alias
local function GetDB()
    return (_G.RCPT and _G.RCPT.db) or RCPT_Config or {}
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
        -- Capture position so we can restore it on next Show
        local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
        savedPoint = { point = point, relativePoint = relativePoint, x = xOfs, y = yOfs }
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

    -- Combat safety: hide immediately when combat starts
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
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
    if savedPoint then
        -- Restore session-saved drag position
        f:SetPoint(savedPoint.point, UIParent, savedPoint.relativePoint, savedPoint.x, savedPoint.y)
    else
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
-- Callback handlers
---------------------------------------------------------------------------
local function OnRCSent(_, payload)
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
    if not frame or not frame:IsShown() then return end
    local confirmed = payload and payload.confirmedCount or 0
    local tracked   = payload and payload.trackedCount or 0
    statusText:SetText("Waiting for responses (" .. confirmed .. "/" .. tracked .. " ready)")
end

local function OnRCAllReady(_, payload)
    if not frame or not frame:IsShown() then return end
    AdvanceTo(3, "success")
    statusText:SetText("All ready!")
end

local function OnRCFailedRetry(_, payload)
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
    if not frame or not frame:IsShown() then return end
    CancelRetryTicker()
    local notReady = payload and payload.notReadyCount or 0
    local tracked  = payload and payload.trackedCount or 0

    AdvanceTo(3, "fail")
    statusText:SetText(string.format("%d of %d not ready. Max retries reached.", notReady, tracked))
    AutoHideAfter(5)
end

local function OnPullStarted(_, payload)
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
    if not frame or not frame:IsShown() then return end
    CancelPullTicker()
    AdvanceTo(4, "fail")
    statusText:SetText("Pull cancelled.")
    AutoHideAfter(3)
end

local function OnCycleComplete()
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
    if frame then
        ResetBreadcrumbs()
        frame:Hide()
    end
    Debug("PullTimers UI torn down.")
end

_G.RCPT_PullTimers_UI_Teardown = Teardown
