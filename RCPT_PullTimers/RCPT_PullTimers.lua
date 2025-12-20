-- RCPT_PullTimers.lua
-- Core runtime for RCPT PullTimers module (load-on-demand)

-- Public frame and module state
local f = CreateFrame("Frame")
local retryCount = 0
local readyMap = {}
local scheduledCleanup
local initiatedByMe = false
local chatEventsRegistered = false

local Module = {}

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

-- Normalize unit/name returns into a single full-name string used as keys
local function MakeFullNameFromParts(name, realm)
    if not name then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function FullNameForUnit(unit)
    local name, realm = UnitFullName(unit)
    return MakeFullNameFromParts(name, realm)
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

-- Start a ready check and ensure chat listeners are active.
-- Declared local and exported explicitly to avoid accidental globals.
local function RCPT_RunReadyCheck()
    retryCount = 0
    RegisterChatEvents()
    readyMap = {}

    local me = FullNameForUnit("player")
    if me then readyMap[me] = true end

    DoReadyCheck()
end

_G.RCPT_RunReadyCheck = RCPT_RunReadyCheck

f:SetScript("OnEvent", function(_, event, ...)
        -- if the player is not able to send a ready check, or the feature is disabled in config, ignore everything
    if (not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player")) or not DB.enableAutoPullTimers then
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
                local me = FullNameForUnit("player")
                if me then readyMap[me] = true end
                Debug("You initiated the ready check")
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
        local name, realm = UnitFullName(unitToken)
        if name then
            local fullName = realm and realm ~= "" and (name .. "-" .. realm) or name
            readyMap[fullName] = isReady
            Debug(fullName .. " is " .. (isReady and "READY" or "NOT ready"))
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
                        local online = UnitIsConnected and UnitIsConnected(unit) or true
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

        if allReady then
            Debug("Everyone is ready, starting pull timer")
            StartPullTimer(DB.pullDuration)
            
            -- Cancel old one before scheduling a new one
            if scheduledCleanup then
                scheduledCleanup:Cancel()
            end

            scheduledCleanup = C_Timer.NewTimer(DB.pullDuration + 1, function()
                Debug("Pull timer expired, cleaning up chat listeners.")
                UnregisterChatEvents()
                scheduledCleanup = nil
                initiatedByMe = false
            end)
        else
            Debug("Not everyone is ready")
            if DB.retryTimeout and retryCount < DB.maxRetries then
                retryCount = retryCount + 1
                C_Timer.After(DB.retryTimeout, function()
                    DoReadyCheck()
                end)
            else
                Debug("Max retries reached")
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
    Debug("PullTimers module torn down.")
end

_G.RCPT_Teardown = Teardown
-- mark inactive when torn down
local oldTeardown = _G.RCPT_Teardown
_G.RCPT_Teardown = function(...)
    if oldTeardown then pcall(oldTeardown, ...) end
    _G.RCPT_MainActive = false
end
