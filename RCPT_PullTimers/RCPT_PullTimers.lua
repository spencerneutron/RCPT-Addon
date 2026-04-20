-- RCPT_PullTimers.lua
-- Core runtime for RCPT PullTimers module (load-on-demand)

-- Public frame and module state
local f = CreateFrame("Frame")
local retryCount = 0
local readyMap = {}
local scheduledCleanup
local initiatedByMe = false
local chatEventsRegistered = false
local trackedTotal = 0

local Module = {}

-- Callback pub/sub for UI consumers
local callbacks = {}

local function FireCallback(event, payload)
    if not callbacks[event] then return end
    for fn in pairs(callbacks[event]) do
        pcall(fn, event, payload)
    end
end

function _G.RCPT_PullTimers_RegisterCallback(event, fn)
    if not event or type(fn) ~= "function" then return end
    if not callbacks[event] then callbacks[event] = {} end
    callbacks[event][fn] = true
end

function _G.RCPT_PullTimers_UnregisterCallback(event, fn)
    if callbacks[event] then
        callbacks[event][fn] = nil
    end
end

function _G.RCPT_PullTimers_UnregisterAllCallbacks()
    callbacks = {}
end

-- Ensure defaults from config.lua are applied (safe-call)
if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end

-- DB alias and refresh helper
local DB = RCPT_Config
local function RefreshDB()
    DB = (_G.RCPT and _G.RCPT.db) or RCPT_Config or {}
end
RefreshDB()

-- Helpers
local function Debug(msg)
    if _G.RCPT_Debug then
        _G.RCPT_Debug(msg)
    end
end

local function StartPullTimer(seconds)
    if C_PartyInfo and C_PartyInfo.DoCountdown then
        C_PartyInfo.DoCountdown(seconds)
    end
end

local function CancelPullTimer()
    if C_PartyInfo and C_PartyInfo.DoCountdown then
        C_PartyInfo.DoCountdown(0)
    end
end

-- ==========================================================================
-- WoW Raid Roster API Notes (verified in-game, April 2026)
-- ==========================================================================
-- UnitInRaid("player")
--   Returns the player's raid index as used by GetRaidRosterInfo (1-based).
--   Returns nil if the player is not in a raid.
--
-- GetRaidRosterInfo(index)
--   Accepts the same index returned by UnitInRaid — no +1 offset needed.
--   Name format varies by server:
--     Same server  -> "Name"           (no realm suffix)
--     Cross server -> "Name-Realm"     (realm appended with hyphen)
--
-- UnitFullName(unit)
--   Returns (name, realm) as two values.
--   Same server  -> ("Name", "Sargeras")   (realm is populated, non-empty)
--   Cross server -> ("Name", "Kel'Thuzad") (realm is populated, non-empty)
--
-- Key difference: GetRaidRosterInfo OMITS the realm for same-server players,
-- while UnitFullName ALWAYS returns a non-empty realm string. Mixing the two
-- as table keys causes lookup mismatches. Any code writing to and reading from
-- the same table (e.g. readyMap) must use a single consistent name source.
-- ==========================================================================

-- Normalize unit/name returns into a single full-name string used as keys
local function MakeFullNameFromParts(name, realm)
    if not name then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function FullNameForUnit(unit)
    local ok, name, realm = pcall(UnitFullName, unit)
    if not ok or not name then return nil end
    return MakeFullNameFromParts(name, realm)
end

-- Resolve a unit's name in the same format that GetRaidRosterInfo returns.
-- In a raid, GetRaidRosterInfo omits the realm for same-server players
-- ("Name") while UnitFullName always populates the realm ("Name", "Realm").
-- Using this function for readyMap keys ensures they match the lookup format
-- used in READY_CHECK_FINISHED and CountConfirmed.
local function RosterNameForUnit(unit)
    if IsInRaid() then
        local raidIndex = UnitInRaid(unit)
        if raidIndex then
            local name = GetRaidRosterInfo(raidIndex)
            if name then return name end
        end
    end
    return FullNameForUnit(unit)
end

-- Check whether the local player is in a tracked subgroup (within maxRequiredGroup).
-- Returns true when either maxRequiredGroup filtering is disabled or the player's
-- subgroup does not exceed it.  Used to decide whether to auto-mark the sender
-- as "ready" so that out-of-group initiators don't inflate the confirmed count.
local function IsPlayerInTrackedGroup()
    if not DB.maxRequiredGroup or DB.maxRequiredGroup <= 0 then
        return true -- filtering disabled, all groups tracked
    end
    if not IsInRaid() then
        return true -- party members are always treated as subgroup 1
    end
    -- Use UnitInRaid to get the player's raid index directly,
    -- avoiding name-format mismatches between UnitFullName and GetRaidRosterInfo.
    local raidIndex = UnitInRaid("player")
    if not raidIndex then return false end
    local _, _, subgroup = GetRaidRosterInfo(raidIndex)
    return subgroup ~= nil and subgroup <= DB.maxRequiredGroup
end

-- Chat event registration helpers
local function RegisterChatEvents()
    if chatEventsRegistered then return end
    if _G.RCPT and _G.RCPT.EncounterRestrictionsActive and _G.RCPT.EncounterRestrictionsActive() then
        Debug("Encounter restrictions active; skipping chat event registration")
        return
    end
    f:RegisterEvent("CHAT_MSG_PARTY")
    f:RegisterEvent("CHAT_MSG_RAID")
    -- include leader-specific events; handler will dedupe duplicate notifications
    f:RegisterEvent("CHAT_MSG_PARTY_LEADER")
    f:RegisterEvent("CHAT_MSG_RAID_LEADER")
    chatEventsRegistered = true
end

local function UnregisterChatEvents()
    if not chatEventsRegistered then return end
    f:UnregisterEvent("CHAT_MSG_PARTY")
    f:UnregisterEvent("CHAT_MSG_RAID")
    f:UnregisterEvent("CHAT_MSG_PARTY_LEADER")
    f:UnregisterEvent("CHAT_MSG_RAID_LEADER")
    chatEventsRegistered = false
end

-- Roster scan: count online members within maxRequiredGroup and return member info helper
local function ComputeTrackedCount()
    local inRaid = IsInRaid()
    local totalMembers = GetNumGroupMembers() or 0
    local count = 0
    for i = 1, totalMembers do
        if inRaid then
            local name, rank, subgroup, level, class, fileName, zone, online = GetRaidRosterInfo(i)
            if name and online then
                if not (DB.maxRequiredGroup and DB.maxRequiredGroup > 0 and subgroup and subgroup > DB.maxRequiredGroup) then
                    count = count + 1
                end
            end
        else
            local unit = (i == 1) and "player" or ("party" .. (i - 1))
            if UnitExists(unit) then
                local online = not UnitIsConnected or UnitIsConnected(unit)
                if online then
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- Count confirmed (ready) entries in readyMap using the same roster, subgroup,
-- and online filtering rules as ComputeTrackedCount, so that confirmedCount
-- stays consistent with trackedTotal in all callback payloads.
local function CountConfirmed()
    local inRaid = IsInRaid()
    local totalMembers = GetNumGroupMembers() or 0
    local n = 0
    for i = 1, totalMembers do
        if inRaid then
            local name, rank, subgroup, level, class, fileName, zone, online = GetRaidRosterInfo(i)
            if name and online then
                if not (DB.maxRequiredGroup and DB.maxRequiredGroup > 0 and subgroup and subgroup > DB.maxRequiredGroup) then
                    if readyMap[name] == true then
                        n = n + 1
                    end
                end
            end
        else
            local unit = (i == 1) and "player" or ("party" .. (i - 1))
            if UnitExists(unit) then
                local uname, realm = UnitFullName(unit)
                if uname then
                    local fullName = realm and realm ~= "" and (uname .. "-" .. realm) or uname
                    local online = not UnitIsConnected or UnitIsConnected(unit)
                    if online and readyMap[fullName] == true then
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

-- ==========================================================================
-- Shared roster helper (extracted for reuse)
-- ==========================================================================
local function GetMemberInfo(index)
    local inRaid = IsInRaid()
    if inRaid then
        local name, rank, subgroup, level, class, fileName, zone, online = GetRaidRosterInfo(index)
        if name then
            return name, subgroup, online
        end
        return nil, nil, nil
    else
        local unit = (index == 1) and "player" or ("party" .. (index - 1))
        if UnitExists(unit) then
            local uname, realm = UnitFullName(unit)
            if uname then
                local fullName = realm and realm ~= "" and (uname .. "-" .. realm) or uname
                local online = not UnitIsConnected or UnitIsConnected(unit)
                return fullName, 1, online
            end
        end
        return nil, nil, nil
    end
end

-- Check if all tracked members are ready based on current readyMap
local function CheckAllReady()
    local totalMembers = GetNumGroupMembers() or 0
    for i = 1, totalMembers do
        local fullName, subgroup, online = GetMemberInfo(i)
        if online and fullName then
            if not (DB.maxRequiredGroup and DB.maxRequiredGroup > 0 and subgroup and subgroup > DB.maxRequiredGroup) then
                if readyMap[fullName] ~= true then
                    return false
                end
            end
        end
    end
    return true
end

-- ==========================================================================
-- Rapid Mode
-- ==========================================================================
local RAPID_RC_LEAD_TIME = 45  -- Send ready check when this many seconds remain
local RAPID_CUTOFF = 10        -- Cancel if RC not passed by this many seconds remaining

local rapid = {
    active = false,
    state = "INACTIVE",    -- INACTIVE, COUNTDOWN, RC_PENDING, DEFERRED, IN_COMBAT
    remaining = 0,
    rcPassed = false,
    rcSent = false,
    userDeferred = false,  -- true only when user explicitly defers (blocks auto-restart)
    ticker = nil,
    pendingRestart = nil,  -- C_Timer handle for post-combat restart (only one at a time)
}

local function RapidMode_CancelTicker()
    if rapid.ticker then
        pcall(function() rapid.ticker:Cancel() end)
        rapid.ticker = nil
    end
end

local function RapidMode_CancelPendingRestart()
    if rapid.pendingRestart then
        pcall(function() rapid.pendingRestart:Cancel() end)
        rapid.pendingRestart = nil
    end
end

local function RapidMode_SendRaidWarning(msg)
    if DB.rapidModeRaidWarning == false then return end
    if IsInRaid() then
        pcall(function() SendChatMessage(msg, "RAID_WARNING") end)
    end
end

local function RapidMode_InitReadyMap()
    readyMap = {}
    if IsPlayerInTrackedGroup() then
        local me = RosterNameForUnit("player")
        if me then readyMap[me] = true end
    end
end

local function RapidMode_StartCountdown(duration)
    -- Clear any pending post-combat restart since we are starting now
    RapidMode_CancelPendingRestart()
    RapidMode_CancelTicker()
    duration = duration or DB.rapidModeDuration or 90
    -- Clamp to configured range
    if duration < 45 then duration = 45 end
    if duration > 360 then duration = 360 end

    rapid.state = "COUNTDOWN"
    rapid.remaining = duration
    rapid.rcPassed = false
    rapid.rcSent = false
    rapid.userDeferred = false

    StartPullTimer(duration)
    FireCallback("RAPID_COUNTDOWN_START", { duration = duration })

    -- Determine when to send the ready check
    local rcTriggerRemaining = RAPID_RC_LEAD_TIME
    if duration <= RAPID_RC_LEAD_TIME + RAPID_CUTOFF then
        -- Not enough runway; send RC immediately
        rcTriggerRemaining = duration
    end

    rapid.ticker = C_Timer.NewTicker(1, function()
        rapid.remaining = rapid.remaining - 1
        FireCallback("RAPID_TICK", { remaining = rapid.remaining, state = rapid.state })

        -- Send ready check at the right moment
        if not rapid.rcSent and rapid.remaining <= rcTriggerRemaining then
            rapid.rcSent = true
            rapid.state = "RC_PENDING"
            RapidMode_InitReadyMap()
            trackedTotal = ComputeTrackedCount()
            DoReadyCheck()
            FireCallback("RAPID_RC_AUTO_SENT", { remaining = rapid.remaining })
            FireCallback("RC_SENT", {
                retryNum = 0, maxRetries = 0,
                confirmedCount = CountConfirmed(), trackedCount = trackedTotal,
            })
        end

        -- Cutoff check: cancel if RC was sent but hasn't passed
        if rapid.rcSent and not rapid.rcPassed and rapid.remaining <= RAPID_CUTOFF then
            -- One final check in case confirms arrived but FINISHED hasn't fired yet
            if CheckAllReady() then
                rapid.rcPassed = true
                FireCallback("RC_ALL_READY", { trackedCount = trackedTotal })
                FireCallback("RAPID_RC_PASSED", {})
            else
                RapidMode_CancelTicker()
                CancelPullTimer()
                rapid.state = "DEFERRED"
                rapid.userDeferred = false  -- auto-deferred, will auto-restart after combat
                RapidMode_SendRaidWarning("Pull canceled - not everyone is ready.")
                FireCallback("RAPID_CUTOFF_CANCEL", {})
                return
            end
        end

        -- Timer reached zero: pull is going through
        if rapid.remaining <= 0 then
            RapidMode_CancelTicker()
            -- State will transition to IN_COMBAT when PLAYER_REGEN_DISABLED fires
            FireCallback("RAPID_PULL_COMPLETE", {})
        end
    end, duration)
end

local function RapidMode_Start()
    if rapid.active then return end
    if not IsInGroup() then
        Debug("Rapid mode requires being in a group")
        return
    end
    if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then
        Debug("Rapid mode requires raid leader or assistant")
        return
    end

    RefreshDB()
    rapid.active = true
    rapid.state = "INACTIVE"
    rapid.userDeferred = false

    -- Register combat events on this frame
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:RegisterEvent("PLAYER_REGEN_DISABLED")

    FireCallback("RAPID_SESSION_START", { duration = DB.rapidModeDuration or 90 })

    -- Start first countdown immediately
    RapidMode_StartCountdown(DB.rapidModeDuration or 90)
end

local function RapidMode_Stop()
    if not rapid.active then return end
    RapidMode_CancelTicker()
    RapidMode_CancelPendingRestart()
    if rapid.state == "COUNTDOWN" or rapid.state == "RC_PENDING" then
        CancelPullTimer()
    end
    rapid.active = false
    rapid.state = "INACTIVE"
    rapid.rcPassed = false
    rapid.rcSent = false
    rapid.userDeferred = false

    f:UnregisterEvent("PLAYER_REGEN_ENABLED")
    f:UnregisterEvent("PLAYER_REGEN_DISABLED")

    FireCallback("RAPID_SESSION_STOP", {})
end

local function RapidMode_Defer()
    if not rapid.active then return end
    if rapid.state ~= "COUNTDOWN" and rapid.state ~= "RC_PENDING" then return end
    RapidMode_CancelTicker()
    CancelPullTimer()
    rapid.state = "DEFERRED"
    rapid.userDeferred = true
    FireCallback("RAPID_DEFERRED", {})
end

local function RapidMode_Restart()
    if not rapid.active then return end
    if rapid.state ~= "DEFERRED" then return end
    RapidMode_StartCountdown(DB.rapidModeDuration or 90)
end

local function RapidMode_Skip(targetSeconds)
    if not rapid.active then return end
    targetSeconds = targetSeconds or DB.rapidModeSkipTo or 30
    if targetSeconds < 15 then targetSeconds = 15 end
    if targetSeconds > 45 then targetSeconds = 45 end

    if rapid.state == "DEFERRED" then
        RapidMode_StartCountdown(targetSeconds)
    elseif rapid.state == "COUNTDOWN" or rapid.state == "RC_PENDING" then
        RapidMode_CancelTicker()
        CancelPullTimer()
        RapidMode_StartCountdown(targetSeconds)
    end
end

-- Export rapid mode API
_G.RCPT_RapidMode_Start = RapidMode_Start
_G.RCPT_RapidMode_Stop = RapidMode_Stop
_G.RCPT_RapidMode_Defer = RapidMode_Defer
_G.RCPT_RapidMode_Restart = RapidMode_Restart
_G.RCPT_RapidMode_Skip = RapidMode_Skip
_G.RCPT_RapidMode_IsActive = function() return rapid.active end
_G.RCPT_RapidMode_GetState = function() return rapid.state end

-- Start a ready check and ensure chat listeners are active.
-- Declared local and exported explicitly to avoid accidental globals.
local function RCPT_RunReadyCheck()
    retryCount = 0
    RegisterChatEvents()
    readyMap = {}

    -- Only auto-mark the sender as ready if they are in a tracked group;
    -- out-of-group initiators must not inflate the confirmed count.
    if IsPlayerInTrackedGroup() then
        local me = RosterNameForUnit("player")
        if me then readyMap[me] = true end
    else
        Debug("Sender is outside tracked groups; not auto-marking as ready")
    end

    DoReadyCheck()
end

_G.RCPT_RunReadyCheck = RCPT_RunReadyCheck

f:SetScript("OnEvent", function(_, event, ...)
    -- Leader/assistant check always applies
    if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then
        return
    end

    -- Rapid mode combat events
    if event == "PLAYER_REGEN_ENABLED" then
        if rapid.active then
            if rapid.userDeferred then
                Debug("Rapid mode: combat ended but user deferred, not restarting")
            else
                -- Cancel any previously pending restart before scheduling a new one
                RapidMode_CancelPendingRestart()
                Debug("Rapid mode: combat ended, scheduling new cycle")
                rapid.pendingRestart = C_Timer.NewTimer(2, function()
                    rapid.pendingRestart = nil
                    if rapid.active and not rapid.userDeferred and rapid.state == "IN_COMBAT" then
                        RapidMode_StartCountdown(DB.rapidModeDuration or 90)
                    end
                end)
            end
        end
        return
    elseif event == "PLAYER_REGEN_DISABLED" then
        if rapid.active then
            -- Cancel everything in-flight: ticker, pending restart, scheduled cleanup
            RapidMode_CancelTicker()
            RapidMode_CancelPendingRestart()
            if scheduledCleanup then
                pcall(function() scheduledCleanup:Cancel() end)
                scheduledCleanup = nil
            end
            if rapid.state == "COUNTDOWN" or rapid.state == "RC_PENDING" then
                CancelPullTimer()
            end
            -- Disarm the ready check pipeline so in-flight confirms/finishes are ignored
            initiatedByMe = false
            readyMap = {}
            rapid.state = "IN_COMBAT"
            rapid.rcSent = false
            rapid.rcPassed = false
            FireCallback("RAPID_COMBAT_START", {})
        end
        return
    end

    -- For non-combat events, require enableAutoPullTimers OR active rapid mode
    if not rapid.active and not DB.enableAutoPullTimers then
        return
    end
    if event == "READY_CHECK" then
        local initiatorUnit = ...

        do
            local isSelf = false
            if _G.RCPT and _G.RCPT.SafeUnitIsUnit then
                isSelf = _G.RCPT.SafeUnitIsUnit("player", initiatorUnit)
            elseif UnitIsUnit then
                local ok_, res_ = pcall(UnitIsUnit, "player", initiatorUnit)
                if ok_ and res_ then isSelf = true end
            end
            if isSelf then
                initiatedByMe = true
                readyMap = {}
                -- Only auto-mark the sender as ready if they are in a tracked group
                if IsPlayerInTrackedGroup() then
                    local me = RosterNameForUnit("player")
                    if me then readyMap[me] = true end
                else
                    Debug("Sender is outside tracked groups; not auto-marking as ready")
                end
                trackedTotal = ComputeTrackedCount()
                Debug("You initiated the ready check")
                FireCallback("RC_SENT", { retryNum = retryCount, maxRetries = DB.maxRetries, confirmedCount = CountConfirmed(), trackedCount = trackedTotal })
            else
                initiatedByMe = false
                Debug("Another player initiated the ready check, ignoring")
            end
        end
    elseif event == "READY_CHECK_CONFIRM" then
        if not initiatedByMe then
            return
        end
        local unitToken, isReady = ...
        local fullName = RosterNameForUnit(unitToken)
        if fullName then
            readyMap[fullName] = isReady
            Debug(fullName .. " is " .. (isReady and "READY" or "NOT ready"))
            FireCallback("RC_CONFIRM", { fullName = fullName, isReady = isReady, confirmedCount = CountConfirmed(), trackedCount = trackedTotal })
        end

    elseif event == "READY_CHECK_FINISHED" then
        if not initiatedByMe then
            return
        end

        Debug("Ready check finished")
        local allReady = true

        local inRaid = IsInRaid()
        local totalMembers = GetNumGroupMembers() or 0

        -- Helper that returns fullName, subgroup, online for the given index
        local function GetMemberInfo(index)
            if inRaid then
                local name, rank, subgroup, level, class, fileName, zone, online = GetRaidRosterInfo(index)
                if name then
                    local fullName = name -- GetRaidRosterInfo already returns the name including realm suffix when present
                    return fullName, subgroup, online
                end
                return nil, nil, nil
            else
                local unit = (index == 1) and "player" or ("party" .. (index - 1))
                if UnitExists(unit) then
                    local name, realm = UnitFullName(unit)
                    if name then
                        local fullName = realm and realm ~= "" and (name .. "-" .. realm) or name
                        local online = not UnitIsConnected or UnitIsConnected(unit)
                        -- treat party members as subgroup 1 for the purpose of maxRequiredGroup checks
                        return fullName, 1, online
                    end
                end
                return nil, nil, nil
            end
        end

        for i = 1, totalMembers do
            local fullName, subgroup, online = GetMemberInfo(i)
            if online and fullName then
                if DB.maxRequiredGroup and DB.maxRequiredGroup > 0 and subgroup and subgroup > DB.maxRequiredGroup then
                    Debug("Skipping " .. fullName .. " in subgroup " .. tostring(subgroup))
                else
                    if readyMap[fullName] ~= true then
                        allReady = false
                        Debug("Missing or not ready: " .. fullName)
                        break
                    end
                end
            end
        end

        if rapid.active then
            -- Ignore stale RC results if we've already transitioned to combat or deferred
            if rapid.state == "IN_COMBAT" or rapid.state == "DEFERRED" or rapid.state == "INACTIVE" then
                Debug("Rapid mode: ignoring late READY_CHECK_FINISHED in state " .. rapid.state)
            elseif allReady then
                rapid.rcPassed = true
                Debug("Rapid mode: RC passed, pull timer continues")
                FireCallback("RC_ALL_READY", { trackedCount = trackedTotal })
                FireCallback("RAPID_RC_PASSED", {})
            else
                rapid.rcPassed = false
                local notReadyCount = trackedTotal - CountConfirmed()
                Debug("Rapid mode: RC not passed, waiting for cutoff")
                FireCallback("RAPID_RC_FAILED", { notReadyCount = notReadyCount, trackedCount = trackedTotal })
            end
        elseif allReady then
            Debug("Everyone is ready, starting pull timer")
            FireCallback("RC_ALL_READY", { trackedCount = trackedTotal })
            StartPullTimer(DB.pullDuration)
            FireCallback("PULL_STARTED", { duration = DB.pullDuration })
            
            -- Cancel old one before scheduling a new one
            if scheduledCleanup then
                scheduledCleanup:Cancel()
            end

            scheduledCleanup = C_Timer.NewTimer(DB.pullDuration + 1, function()
                Debug("Pull timer expired, cleaning up chat listeners.")
                UnregisterChatEvents()
                scheduledCleanup = nil
                initiatedByMe = false
                FireCallback("CYCLE_COMPLETE", {})
            end)
        else
            Debug("Not everyone is ready")
            if DB.retryTimeout and retryCount < DB.maxRetries then
                retryCount = retryCount + 1
                local notReadyCount = trackedTotal - CountConfirmed()
                FireCallback("RC_FAILED_RETRY", { notReadyCount = notReadyCount, trackedCount = trackedTotal, retryNum = retryCount, maxRetries = DB.maxRetries, retryTimeout = DB.retryTimeout })
                C_Timer.After(DB.retryTimeout, function()
                    trackedTotal = ComputeTrackedCount()
                    FireCallback("RC_SENT", { retryNum = retryCount, maxRetries = DB.maxRetries, confirmedCount = CountConfirmed(), trackedCount = trackedTotal })
                    DoReadyCheck()
                end)
            else
                Debug("Max retries reached")
                local notReadyCount = trackedTotal - CountConfirmed()
                FireCallback("RC_FAILED_FINAL", { notReadyCount = notReadyCount, trackedCount = trackedTotal })
                UnregisterChatEvents()
                initiatedByMe = false
            end
        end

    elseif event:match("^CHAT_MSG_") then
        if _G.RCPT and _G.RCPT.EncounterRestrictionsActive and _G.RCPT.EncounterRestrictionsActive() then
            Debug("Skipping chat parsing due to encounter restrictions")
            return
        end
        Debug("Chat message received: " .. event)
        local msg = select(1, ...)
        if not msg then return end
        msg = msg:lower()
        for _, keyword in ipairs(DB.cancelKeywords or {}) do
            if msg:match(keyword:lower()) then
                Debug("Cancel keyword detected: " .. keyword)
                CancelPullTimer()
                FireCallback("PULL_CANCELLED", {})
                -- Also defer rapid mode if active
                if rapid.active and (rapid.state == "COUNTDOWN" or rapid.state == "RC_PENDING") then
                    RapidMode_CancelTicker()
                    rapid.state = "DEFERRED"
                    rapid.userDeferred = false
                    FireCallback("RAPID_DEFERRED", {})
                end
                break
            end
        end
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        -- signature: type, state
        local rtype, rstate = ...
        -- try to resolve relevant enum values safely
        local okT, tEncounter = pcall(function() return Enum and Enum.AddOnRestrictionType and Enum.AddOnRestrictionType.Encounter end)
        local okC, tChallenge = pcall(function() return Enum and Enum.AddOnRestrictionType and Enum.AddOnRestrictionType.ChallengeMode end)
        local okS, sActive = pcall(function() return Enum and Enum.AddOnRestrictionState and Enum.AddOnRestrictionState.Active end)
        local okA, sActivating = pcall(function() return Enum and Enum.AddOnRestrictionState and Enum.AddOnRestrictionState.Activating end)
        local okI, sInactive = pcall(function() return Enum and Enum.AddOnRestrictionState and Enum.AddOnRestrictionState.Inactive end)

        local isRelevant = false
        if okT and okC then
            if rtype == tEncounter or rtype == tChallenge then isRelevant = true end
        end
        if not isRelevant then return end

        -- If restrictions are activating/active, unregister chat listeners immediately
        if (okS and okA) and (rstate == sActivating or rstate == sActive) then
            Debug("Restriction activating/active for relevant type; unregistering chat events")
            UnregisterChatEvents()
        elseif okI and rstate == sInactive then
            -- If restrictions cleared, re-register chat events if we had initiated a ready check
            Debug("Restriction inactive for relevant type; attempting to re-register chat events")
            if initiatedByMe then
                RegisterChatEvents()
            end
        end
    end
end)

local function InitModule()
    -- Register events so the frame receives ready-check lifecycle events
    f:RegisterEvent("PLAYER_LOGIN")
    f:RegisterEvent("READY_CHECK")
    f:RegisterEvent("READY_CHECK_CONFIRM")
    f:RegisterEvent("READY_CHECK_FINISHED")
    f:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
    _G.RCPT_MainActive = true
end

-- expose initializer for manager to re-attach after teardown
_G.RCPT_Initialize = InitModule

function Module.Init(addon)
    -- allow addon to provide DB aliases if present
    if addon and addon.db then DB = addon.db end
    RefreshDB()
    InitModule()
end

-- Register with core Addon registry if available, otherwise initialize immediately
if _G.RCPT and type(_G.RCPT.RegisterModule) == "function" then
    _G.RCPT:RegisterModule("PullTimers", Module)
else
    InitModule()
end

-- Teardown: unregister events and stop timers so the addon can be effectively disabled
local function Teardown()
    -- Stop rapid mode if active
    if rapid.active then
        RapidMode_CancelTicker()
        RapidMode_CancelPendingRestart()
        rapid.active = false
        rapid.state = "INACTIVE"
        pcall(function() f:UnregisterEvent("PLAYER_REGEN_ENABLED") end)
        pcall(function() f:UnregisterEvent("PLAYER_REGEN_DISABLED") end)
    end
    f:UnregisterEvent("READY_CHECK")
    f:UnregisterEvent("READY_CHECK_CONFIRM")
    f:UnregisterEvent("READY_CHECK_FINISHED")
    f:UnregisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
    UnregisterChatEvents()
    if scheduledCleanup then
        pcall(function() scheduledCleanup:Cancel() end)
        scheduledCleanup = nil
    end
    retryCount = 0
    initiatedByMe = false
    readyMap = {}
    trackedTotal = 0
    FireCallback("CYCLE_COMPLETE", {})
    if _G.RCPT_PullTimers_UI_Teardown then pcall(_G.RCPT_PullTimers_UI_Teardown) end
    Debug("PullTimers module torn down.")
end

_G.RCPT_Teardown = Teardown
-- mark inactive when torn down
local oldTeardown = _G.RCPT_Teardown
_G.RCPT_Teardown = function(...)
    if oldTeardown then pcall(oldTeardown, ...) end
    _G.RCPT_MainActive = false
end
