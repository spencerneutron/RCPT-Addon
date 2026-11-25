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

-- API wrappers: the C_ forms are primary; the old globals only exist on 12.x
-- behind the loadDeprecationFallbacks CVar.
local function DoReadyCheckCompat()
    if C_PartyInfo and C_PartyInfo.DoReadyCheck then
        return C_PartyInfo.DoReadyCheck()
    elseif DoReadyCheck then
        return DoReadyCheck()
    end
end

local function SendChatMessageCompat(msg, chatType, languageID, target)
    if C_ChatInfo and C_ChatInfo.SendChatMessage then
        return C_ChatInfo.SendChatMessage(msg, chatType, languageID, target)
    elseif SendChatMessage then
        return SendChatMessage(msg, chatType, languageID, target)
    end
end

-- Ensure defaults are applied (safe-call)
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
-- WoW's ready check runs ~30s before READY_CHECK_FINISHED fires. Keep
-- (LEAD_TIME - 30) - CUTOFF >= ~15s of buffer so the last responder + tick
-- jitter can't push us past the cutoff.
local RAPID_RC_LEAD_TIME = 55  -- Send ready check when this many seconds remain
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
    -- Session aggregates: persist across cycles until the next RapidMode_Start.
    -- Cleared on Start so the report remains readable after Stop until a new session begins.
    session = {
        startedAt = nil,
        cancelCount = 0,
        pulledCount = 0,
        offenders = {},  -- [fullName] = { class, noCount, noResponseCount }
    },
}

local function RapidMode_ResetSession()
    rapid.session = {
        startedAt = GetTime(),
        cancelCount = 0,
        pulledCount = 0,
        offenders = {},
    }
end

-- Walk the tracked roster (same filters as CheckAllReady / CountConfirmed) and
-- return every member who isn't ready, classified as explicit "no" or "noresponse".
local function GetNotReadyTrackedPlayers()
    local results = {}
    local inRaid = IsInRaid()
    local totalMembers = GetNumGroupMembers() or 0
    for i = 1, totalMembers do
        if inRaid then
            local name, _, subgroup, _, _, fileName, _, online = GetRaidRosterInfo(i)
            if name and online then
                if not (DB.maxRequiredGroup and DB.maxRequiredGroup > 0 and subgroup and subgroup > DB.maxRequiredGroup) then
                    local rm = readyMap[name]
                    if rm ~= true then
                        table.insert(results, {
                            name = name,
                            class = fileName,
                            reason = (rm == false) and "no" or "noresponse",
                        })
                    end
                end
            end
        else
            local unit = (i == 1) and "player" or ("party" .. (i - 1))
            if UnitExists(unit) then
                local uname, realm = UnitFullName(unit)
                if uname then
                    local fullName = (realm and realm ~= "") and (uname .. "-" .. realm) or uname
                    local online = not UnitIsConnected or UnitIsConnected(unit)
                    if online then
                        local rm = readyMap[fullName]
                        if rm ~= true then
                            local _, classFile = UnitClass(unit)
                            table.insert(results, {
                                name = fullName,
                                class = classFile,
                                reason = (rm == false) and "no" or "noresponse",
                            })
                        end
                    end
                end
            end
        end
    end
    return results
end

-- Increment session offender counters and the session cancel counter.
-- Called only at actual cancellation points (early-NO, cutoff). RC_FAILED at
-- READY_CHECK_FINISHED does NOT attribute, because a successful late-confirm
-- can still rescue the cycle before the cutoff.
local function AttributeOffenders(notReady)
    rapid.session.cancelCount = (rapid.session.cancelCount or 0) + 1
    if not notReady then return end
    for _, info in ipairs(notReady) do
        local entry = rapid.session.offenders[info.name]
        if not entry then
            entry = { class = info.class, noCount = 0, noResponseCount = 0 }
            rapid.session.offenders[info.name] = entry
        end
        if info.class and not entry.class then entry.class = info.class end
        if info.reason == "no" then
            entry.noCount = entry.noCount + 1
        else
            entry.noResponseCount = entry.noResponseCount + 1
        end
    end
end

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

-- Post-wipe timing, shared by the in-session restart and the wipe prompt. Waits
-- until the raid's cooldown reports are in: Comms sends at SEND_DELAY (2 s) +
-- up to SEND_JITTER (1.5 s) = 3.5 s, plus 1.5 s margin for delivery. Reports
-- that come later (Comms retries) still extend a running countdown.
local RAPID_RESTART_DELAY = 5
local RAPID_PROMPT_RETRY = 3   -- leader still in combat: one more try this many seconds later
local wipePromptTimer

local function CancelWipePrompt()
    if wipePromptTimer then
        pcall(function() wipePromptTimer:Cancel() end)
        wipePromptTimer = nil
    end
end

local function RapidMode_SendRaidWarning(msg)
    if DB.rapidModeRaidWarning == false then return end
    if IsInRaid() then
        pcall(function() SendChatMessageCompat(msg, "RAID_WARNING") end)
    end
end

local function RapidMode_InitReadyMap()
    readyMap = {}
    if IsPlayerInTrackedGroup() then
        local me = RosterNameForUnit("player")
        if me then readyMap[me] = true end
    end
end

-- When to send the ready check for a countdown of `duration` seconds.
local function RapidMode_RCTrigger(duration)
    if duration <= RAPID_RC_LEAD_TIME + RAPID_CUTOFF then
        -- Not enough runway; send RC immediately (on the first tick)
        return duration
    end
    return RAPID_RC_LEAD_TIME
end

-- Dynamic timer: cover the longest short cooldown still running after a wipe.
local RAPID_CD_BUFFER = 5      -- seconds added on top of the longest cooldown
local RAPID_MAX_DURATION = 360
local RAPID_MIN_ADJUST = 15    -- floor for Adjust; above RAPID_CUTOFF so the cutoff rule still runs
local RAPID_EXTEND_MIN = 3     -- an automatic extension must add at least this many seconds

local function IsSecretValue(v)
    if v == nil or not issecretvalue then return false end
    local ok, s = pcall(issecretvalue, v)
    return not ok or s == true
end

local function SpellNameOrNil(spellID)
    if type(spellID) ~= "number" or spellID <= 0 then return nil end
    if not (C_Spell and C_Spell.GetSpellName) then return nil end
    local ok, name = pcall(C_Spell.GetSpellName, spellID)
    if not ok or IsSecretValue(name) or type(name) ~= "string" or name == "" then return nil end
    return name
end

-- True when a Comms sender key is the local player (Comms stores the player's own
-- scan under its "Name-Realm" key, the same form FullNameForUnit returns).
local function IsSelfSender(sender)
    return type(sender) == "string" and sender == FullNameForUnit("player")
end

-- "Thrall: Ascendance 72s" (spell unknown: "Thrall: cooldown 72s"); own report
-- without the name: "Ascendance 72s".
local function ReportReason(sender, remaining, spellID)
    local text = string.format("%s %ds", SpellNameOrNil(spellID) or "cooldown", math.floor(remaining + 0.5))
    if IsSelfSender(sender) then return text end
    local who = type(sender) == "string" and (sender:match("^([^%-]+)") or sender) or "?"
    return who .. ": " .. text
end

-- Returns duration, info = { base, dynamic, reason, source }. source is "self",
-- the reporting player's name, or nil. Any failure falls back to the base.
local function RapidMode_ComputeDuration()
    local base = DB.rapidModeDuration or 90
    local info = { base = base, dynamic = false, reason = nil, source = nil }
    if DB.rapidDynamicTimer == false then return base, info end

    local best = base
    local addon = _G.RCPT
    local cd = addon and addon.Cooldowns
    if cd and cd.Scan then
        -- Scan returns nil while CanRead() is false (combat / encounter restrictions)
        local ok, res = pcall(cd.Scan)
        if ok and type(res) == "table" and type(res.remaining) == "number" and res.remaining > 0 then
            local want = res.remaining + RAPID_CD_BUFFER
            if want > best then
                best = want
                info.source = "self"
                local okD, text = pcall(cd.Describe, res)
                info.reason = (okD and type(text) == "string") and text or nil
            end
        end
    end
    local comms = addon and addon.Comms
    if comms and comms.GetLongestReported then
        local ok, rem, sender, spellID = pcall(comms.GetLongestReported)
        if ok and type(rem) == "number" and rem > 0 then
            local want = rem + RAPID_CD_BUFFER
            if want > best then
                best = want
                info.source = IsSelfSender(sender) and "self" or sender
                info.reason = ReportReason(sender, rem, spellID)
            end
        end
    end

    if best > base then
        info.dynamic = true
        best = math.min(math.ceil(best), RAPID_MAX_DURATION)
    else
        info.source, info.reason = nil, nil
    end
    return best, info
end

-- Per-second ticker for the current cycle; counts rapid.remaining down to 0.
-- Shared by StartCountdown and Skip so the tick logic lives in one place.
local function RapidMode_StartTicker(rcTriggerRemaining)
    rapid.ticker = C_Timer.NewTicker(1, function()
        rapid.remaining = rapid.remaining - 1
        FireCallback("RAPID_TICK", { remaining = rapid.remaining, state = rapid.state })

        -- Send ready check at the right moment
        if not rapid.rcSent and rapid.remaining <= rcTriggerRemaining then
            rapid.rcSent = true
            rapid.state = "RC_PENDING"
            RapidMode_InitReadyMap()
            trackedTotal = ComputeTrackedCount()
            DoReadyCheckCompat()
            FireCallback("RAPID_RC_AUTO_SENT", { remaining = rapid.remaining })
            FireCallback("RC_SENT", {
                retryNum = 0, maxRetries = 0,
                confirmedCount = CountConfirmed(), trackedCount = trackedTotal,
            })
        end

        -- Early-pass: WoW only fires READY_CHECK_FINISHED on the 30s timeout,
        -- not when the last confirm arrives, so promote eagerly once everyone
        -- has confirmed to avoid racing the cutoff.
        if rapid.rcSent and not rapid.rcPassed and CheckAllReady() then
            rapid.rcPassed = true
            FireCallback("RC_ALL_READY", { trackedCount = trackedTotal })
            FireCallback("RAPID_RC_PASSED", {})
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
                local notReady = GetNotReadyTrackedPlayers()
                AttributeOffenders(notReady)
                RapidMode_SendRaidWarning("Pull canceled - not everyone is ready.")
                FireCallback("RAPID_CUTOFF_CANCEL", { notReady = notReady })
                return
            end
        end

        -- Timer reached zero: pull is going through
        if rapid.remaining <= 0 then
            RapidMode_CancelTicker()
            rapid.session.pulledCount = (rapid.session.pulledCount or 0) + 1
            -- State will transition to IN_COMBAT when PLAYER_REGEN_DISABLED fires
            FireCallback("RAPID_PULL_COMPLETE", {})
        end
    end, rapid.remaining)
end

-- allowShort: only Skip passes it; every other caller keeps the 45 s floor.
-- info: optional { base, dynamic, reason } from RapidMode_ComputeDuration.
local function RapidMode_StartCountdown(duration, allowShort, info)
    -- Clear any pending post-combat restart since we are starting now
    RapidMode_CancelPendingRestart()
    RapidMode_CancelTicker()
    duration = duration or DB.rapidModeDuration or 90
    -- Clamp to configured range
    if not allowShort and duration < 45 then duration = 45 end
    if duration > 360 then duration = 360 end

    rapid.state = "COUNTDOWN"
    rapid.remaining = duration
    rapid.rcPassed = false
    rapid.rcSent = false
    rapid.userDeferred = false

    -- Determine when to send the ready check
    local rcTriggerRemaining = RapidMode_RCTrigger(duration)

    StartPullTimer(duration)
    FireCallback("RAPID_COUNTDOWN_START", {
        duration = duration, rcAt = rcTriggerRemaining,
        base = (info and info.base) or duration,
        dynamic = (info and info.dynamic) == true,
        reason = info and info.reason or nil,
    })

    RapidMode_StartTicker(rcTriggerRemaining)
end

-- Returns true when the session starts, or false and a short user-facing reason.
local function RapidMode_Start()
    if rapid.active then return false, "a session is already running." end
    if InCombatLockdown() then return false, "you are in combat." end
    if not IsInGroup() then
        Debug("Rapid mode requires being in a group")
        return false, "you are not in a party or raid."
    end
    if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then
        Debug("Rapid mode requires raid leader or assistant")
        return false, "you are not the group leader or an assistant."
    end

    RefreshDB()
    CancelWipePrompt()
    rapid.active = true
    rapid.state = "INACTIVE"
    rapid.userDeferred = false
    RapidMode_ResetSession()

    -- Register combat events on this frame
    f:RegisterEvent("ENCOUNTER_END")
    f:RegisterEvent("PLAYER_REGEN_DISABLED")

    local duration, info = RapidMode_ComputeDuration()
    FireCallback("RAPID_SESSION_START", { duration = duration })

    -- Start first countdown immediately
    RapidMode_StartCountdown(duration, false, info)
    return true
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

    -- ENCOUNTER_END stays registered for the module's lifetime (wipe prompt)
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
    local duration, info = RapidMode_ComputeDuration()
    RapidMode_StartCountdown(duration, false, info)
end

-- True while a countdown is really running (the ticker stops at 0 but the state
-- stays COUNTDOWN / RC_PENDING until combat starts).
local function RapidMode_IsCounting()
    return rapid.active and rapid.ticker ~= nil and rapid.remaining > 0
        and (rapid.state == "COUNTDOWN" or rapid.state == "RC_PENDING")
end

-- Move the running cycle to newRemaining seconds; rcSent / rcPassed / readyMap
-- stay as they are. Neither a pull nor a cancel: no session counters change.
-- extra: optional fields merged into the RAPID_SKIPPED payload (e.g. reason).
local function RapidMode_JumpTo(newRemaining, extra)
    RapidMode_CancelTicker()
    CancelPullTimer()
    rapid.remaining = newRemaining
    StartPullTimer(newRemaining)
    local rcTrigger = RapidMode_RCTrigger(newRemaining)
    local payload = { remaining = newRemaining, rcSent = rapid.rcSent, rcPassed = rapid.rcPassed }
    if not rapid.rcSent then payload.rcAt = rcTrigger end
    if extra then
        for k, v in pairs(extra) do payload[k] = v end
    end
    FireCallback("RAPID_SKIPPED", payload)
    -- If the RC has not gone out yet, the trigger sends it when remaining reaches rcTrigger
    RapidMode_StartTicker(rcTrigger)
end

-- Move the running countdown by delta seconds (may lengthen). Result clamped
-- RAPID_MIN_ADJUST..RAPID_MAX_DURATION. Returns true, or false and a reason.
local function RapidMode_AdjustInternal(delta, extra)
    delta = tonumber(delta)
    if not delta or delta ~= delta then return false, "not a number." end
    if not RapidMode_IsCounting() then return false, "no Rapid Mode countdown is running." end
    delta = math.floor(delta + 0.5)
    local target = rapid.remaining + delta
    if target < RAPID_MIN_ADJUST then target = RAPID_MIN_ADJUST end
    if target > RAPID_MAX_DURATION then target = RAPID_MAX_DURATION end
    -- Clamping must never move the countdown the other way than asked
    if (delta < 0 and target >= rapid.remaining) or (delta > 0 and target <= rapid.remaining) or delta == 0 then
        return false, "countdown already at its limit (" .. rapid.remaining .. "s)."
    end
    RapidMode_JumpTo(target, extra)
    return true
end

local function RapidMode_Adjust(delta)
    return RapidMode_AdjustInternal(delta)
end

-- Called by Comms for each valid report from a group member. Extends a running
-- countdown to cover it (at most to report + buffer), never after the pull.
local function RapidMode_OnCooldownReport(sender, remaining, spellID)
    if DB.rapidDynamicTimer == false then return end
    if type(remaining) ~= "number" or remaining <= 0 then return end
    if not RapidMode_IsCounting() then return end
    local want = math.min(math.ceil(remaining + RAPID_CD_BUFFER), RAPID_MAX_DURATION)
    -- Each extension restarts the Blizzard countdown (chat line, boss-mod bars):
    -- skip small ones so several close reports do not each restart it.
    if want < rapid.remaining + RAPID_EXTEND_MIN then return end
    local reason = ReportReason(sender, remaining, spellID)
    Debug("Rapid mode: extending countdown to " .. want .. "s for " .. reason)
    RapidMode_AdjustInternal(want - rapid.remaining,
        { reason = reason, source = IsSelfSender(sender) and "self" or sender })
end

local function RapidMode_Skip(targetSeconds)
    if not rapid.active then return end
    targetSeconds = tonumber(targetSeconds)
    if not targetSeconds or targetSeconds ~= targetSeconds then
        targetSeconds = tonumber(DB.rapidModeSkipTo) or 30
    end
    targetSeconds = math.floor(targetSeconds)
    if targetSeconds < 15 then targetSeconds = 15 end
    if targetSeconds > 45 then targetSeconds = 45 end

    if rapid.state == "DEFERRED" then
        -- Fresh cycle of exactly N s; N <= 45 is short runway, so the RC goes out at once
        RapidMode_StartCountdown(targetSeconds, true)
    elseif rapid.state == "COUNTDOWN" or rapid.state == "RC_PENDING" then
        if rapid.remaining <= targetSeconds then
            Debug("Rapid mode: skip ignored, " .. rapid.remaining .. "s already <= " .. targetSeconds .. "s")
            return
        end
        -- Jump the current cycle; ready-check state is kept (see RapidMode_JumpTo).
        -- targetSeconds <= 45 is short runway: an RC not yet sent goes out on the next tick.
        RapidMode_JumpTo(targetSeconds)
    end
end

-- Session report: summarises cancels/pulls and top offenders over the session.
local REPORT_OFFENDER_CAP = 10

local function FormatReportDuration(sec)
    sec = math.max(0, math.floor(sec or 0))
    if sec >= 3600 then
        return string.format("%dh%dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
    elseif sec >= 60 then
        return string.format("%dm%ds", math.floor(sec / 60), sec % 60)
    end
    return sec .. "s"
end

local function ClassColorCode(class)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        if c.colorStr then return "|c" .. c.colorStr end
        return string.format("|cff%02x%02x%02x",
            math.floor((c.r or 1) * 255),
            math.floor((c.g or 1) * 255),
            math.floor((c.b or 1) * 255))
    end
    return "|cffaaaaaa"
end

local function BuildSessionReport()
    local s = rapid.session or {}
    local offenders = {}
    for name, data in pairs(s.offenders or {}) do
        table.insert(offenders, {
            name = name,
            class = data.class,
            noCount = data.noCount or 0,
            noResponseCount = data.noResponseCount or 0,
            total = (data.noCount or 0) + (data.noResponseCount or 0),
        })
    end
    table.sort(offenders, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    while #offenders > REPORT_OFFENDER_CAP do table.remove(offenders) end
    local durationSec = 0
    if s.startedAt then durationSec = math.max(0, math.floor(GetTime() - s.startedAt)) end
    return {
        durationSec = durationSec,
        cancelCount = s.cancelCount or 0,
        pulledCount = s.pulledCount or 0,
        topOffenders = offenders,
    }
end

local function PrintSessionReport()
    local r = BuildSessionReport()
    print(string.format("|cff00ccff[RCPT Rapid Report]|r duration %s | %d pulled | %d canceled",
        FormatReportDuration(r.durationSec), r.pulledCount, r.cancelCount))
    if #r.topOffenders == 0 then
        print("  No cancelled pulls this session.")
        return
    end
    print("  Top offenders (NO / no-response):")
    for i, o in ipairs(r.topOffenders) do
        print(string.format("  %d. %s%s|r  %d / %d", i, ClassColorCode(o.class), o.name, o.noCount, o.noResponseCount))
    end
end

local function PostSessionReport()
    if not IsInRaid() then
        print("|cffff0000[RCPT]|r Not in a raid; rapid report not posted.")
        return
    end
    local r = BuildSessionReport()
    SendChatMessageCompat(string.format("[RCPT Rapid] duration %s | %d pulled | %d canceled.",
        FormatReportDuration(r.durationSec), r.pulledCount, r.cancelCount), "RAID")
    if #r.topOffenders == 0 then return end
    SendChatMessageCompat("Top offenders (NO / no-response):", "RAID")
    for i, o in ipairs(r.topOffenders) do
        SendChatMessageCompat(string.format("%d. %s  %d / %d", i, o.name, o.noCount, o.noResponseCount), "RAID")
    end
end

-- Export rapid mode API
_G.RCPT_RapidMode_Start = RapidMode_Start
_G.RCPT_RapidMode_Stop = RapidMode_Stop
_G.RCPT_RapidMode_Defer = RapidMode_Defer
_G.RCPT_RapidMode_Restart = RapidMode_Restart
_G.RCPT_RapidMode_Skip = RapidMode_Skip
_G.RCPT_RapidMode_Adjust = RapidMode_Adjust
_G.RCPT_RapidMode_OnCooldownReport = RapidMode_OnCooldownReport
_G.RCPT_RapidMode_ComputeDuration = RapidMode_ComputeDuration

-- success 0 = wipe. A secret or unknown value is treated as "not a wipe".
local function IsWipeResult(success)
    if success == nil or IsSecretValue(success) then return false end
    return success == 0
end

-- Outside a session: offer Rapid Mode to a leader / assistant after a wipe.
-- Fires after RAPID_RESTART_DELAY so `suggested` includes the raid's reports;
-- if the leader is still in combat then, tries once more RAPID_PROMPT_RETRY later.
local function RapidMode_ScheduleWipePrompt()
    if rapid.active or DB.rapidWipePrompt == false or not IsInGroup() then return end
    CancelWipePrompt()
    local function Fire(retried)
        wipePromptTimer = nil
        if rapid.active or DB.rapidWipePrompt == false or not IsInGroup() then return end
        if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then return end
        if InCombatLockdown() then
            if retried then
                Debug("Rapid mode: wipe prompt dropped, still in combat")
            else
                wipePromptTimer = C_Timer.NewTimer(RAPID_PROMPT_RETRY, function() Fire(true) end)
            end
            return
        end
        local duration, info = RapidMode_ComputeDuration()
        FireCallback("RAPID_WIPE_PROMPT", { suggested = duration, reason = info.reason })
    end
    wipePromptTimer = C_Timer.NewTimer(RAPID_RESTART_DELAY, function() Fire(false) end)
end
_G.RCPT_RapidMode_IsActive = function() return rapid.active end
_G.RCPT_RapidMode_GetState = function() return rapid.state end
_G.RCPT_RapidMode_GetSessionReport = BuildSessionReport
_G.RCPT_RapidMode_PrintSessionReport = PrintSessionReport
_G.RCPT_RapidMode_PostSessionReport = PostSessionReport

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

    DoReadyCheckCompat()
end

_G.RCPT_RunReadyCheck = RCPT_RunReadyCheck

f:SetScript("OnEvent", function(_, event, ...)
    -- A new pull: drop a pending or shown wipe prompt (before the leader check)
    if event == "ENCOUNTER_START" then
        CancelWipePrompt()
        FireCallback("RAPID_WIPE_PROMPT_CANCEL", {})
        return
    end
    -- Leader/assistant check always applies
    if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then
        return
    end

    -- Rapid mode combat events
    if event == "ENCOUNTER_END" then
        if rapid.active then
            local encounterID, encounterName, difficultyID, groupSize, success = ...
            if success == 1 then
                Debug("Rapid mode: encounter " .. tostring(encounterName) .. " killed, ending session")
                RapidMode_SendRaidWarning("Boss down! Rapid mode ended.")
                RapidMode_Stop()
            elseif rapid.userDeferred then
                Debug("Rapid mode: encounter ended but user deferred, not restarting")
            else
                -- Cancel any previously pending restart before scheduling a new one
                RapidMode_CancelPendingRestart()
                Debug("Rapid mode: encounter ended (" .. tostring(encounterName) .. ", success=" .. tostring(success) .. "), scheduling new cycle")
                rapid.pendingRestart = C_Timer.NewTimer(RAPID_RESTART_DELAY, function()
                    rapid.pendingRestart = nil
                    if rapid.active and not rapid.userDeferred and rapid.state == "IN_COMBAT" then
                        -- Own scan only counts if cooldowns are readable now; never waits
                        local duration, info = RapidMode_ComputeDuration()
                        RapidMode_StartCountdown(duration, false, info)
                    end
                end)
            end
        else
            local success = select(5, ...)
            if IsWipeResult(success) then RapidMode_ScheduleWipePrompt() end
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

            -- A NO from a tracked player guarantees the cycle will fail.
            -- Cancel the pull immediately rather than waiting for the cutoff.
            if not isReady and rapid.active and (rapid.state == "COUNTDOWN" or rapid.state == "RC_PENDING") then
                local tracked = true
                if DB.maxRequiredGroup and DB.maxRequiredGroup > 0 and IsInRaid() then
                    local raidIndex = UnitInRaid(unitToken)
                    if raidIndex then
                        local _, _, subgroup = GetRaidRosterInfo(raidIndex)
                        tracked = subgroup ~= nil and subgroup <= DB.maxRequiredGroup
                    else
                        tracked = false
                    end
                end
                if tracked then
                    Debug("Tracked player " .. fullName .. " responded NO; canceling pull early")
                    RapidMode_CancelTicker()
                    CancelPullTimer()
                    rapid.state = "DEFERRED"
                    rapid.userDeferred = false
                    local _, classFile = UnitClass(unitToken)
                    local notReady = { { name = fullName, class = classFile, reason = "no" } }
                    AttributeOffenders(notReady)
                    RapidMode_SendRaidWarning("Pull canceled - " .. fullName .. " not ready.")
                    FireCallback("RAPID_CUTOFF_CANCEL", { notReady = notReady, culprit = fullName })
                end
            end
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
                -- Display-only: a late confirm can still rescue this cycle before
                -- the cutoff, so do NOT call AttributeOffenders here.
                local notReady = GetNotReadyTrackedPlayers()
                Debug("Rapid mode: RC not passed, waiting for cutoff")
                FireCallback("RAPID_RC_FAILED", { notReadyCount = notReadyCount, trackedCount = trackedTotal, notReady = notReady })
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
                    DoReadyCheckCompat()
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
    -- Module lifetime: in-session restart and the out-of-session wipe prompt
    f:RegisterEvent("ENCOUNTER_END")
    f:RegisterEvent("ENCOUNTER_START")  -- hides the wipe prompt when the next pull starts
    -- Comms loads after this file; on first load it initialises itself, this covers re-init
    local comms = _G.RCPT and _G.RCPT.Comms
    if comms and comms.Init then pcall(comms.Init) end
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
        pcall(function() f:UnregisterEvent("PLAYER_REGEN_DISABLED") end)
    end
    pcall(function() f:UnregisterEvent("ENCOUNTER_END") end)
    pcall(function() f:UnregisterEvent("ENCOUNTER_START") end)
    CancelWipePrompt()
    local comms = _G.RCPT and _G.RCPT.Comms
    if comms and comms.Teardown then pcall(comms.Teardown) end
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
