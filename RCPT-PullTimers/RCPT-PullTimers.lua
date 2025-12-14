-- RCPT-PullTimers.lua
-- Core runtime for RCPT PullTimers module (load-on-demand)

-- Public frame and module state
local f = CreateFrame("Frame")
local retryCount = 0
local readyMap = {}
local scheduledCleanup
local initiatedByMe = false

-- Ensure defaults from config.lua are applied (safe-call)
if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end

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

-- Chat event registration helpers
local function RegisterChatEvents()
    f:RegisterEvent("CHAT_MSG_PARTY")
    f:RegisterEvent("CHAT_MSG_RAID")
    f:RegisterEvent("CHAT_MSG_PARTY_LEADER")
    f:RegisterEvent("CHAT_MSG_RAID_LEADER")
end

local function UnregisterChatEvents()
    f:UnregisterEvent("CHAT_MSG_PARTY")
    f:UnregisterEvent("CHAT_MSG_RAID")
    f:UnregisterEvent("CHAT_MSG_PARTY_LEADER")
    f:UnregisterEvent("CHAT_MSG_RAID_LEADER")
end

-- Start a ready check and ensure chat listeners are active.
-- Declared local and exported explicitly to avoid accidental globals.
local function RCPT_RunReadyCheck()
    retryCount = 0
    RegisterChatEvents()
    readyMap = {}

    local me = UnitFullName("player")
    readyMap[me] = true

    DoReadyCheck()
end

_G.RCPT_RunReadyCheck = RCPT_RunReadyCheck

f:SetScript("OnEvent", function(_, event, ...)
        -- if the player is not able to send a ready check, ignore everything
    if not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then
        return
    end
    if event == "READY_CHECK" then
        local initiatorUnit = ...

        if UnitIsUnit("player", initiatorUnit) then
            initiatedByMe = true
            readyMap = {}
            readyMap[UnitFullName("player")] = true
            Debug("You initiated the ready check")
        else
            initiatedByMe = false
            Debug("Another player initiated the ready check, ignoring")
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
                if RCPT_Config.maxRequiredGroup and RCPT_Config.maxRequiredGroup > 0 and subgroup and subgroup > RCPT_Config.maxRequiredGroup then
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
            StartPullTimer(RCPT_Config.pullDuration)
            
            -- Cancel old one before scheduling a new one
            if scheduledCleanup then
                scheduledCleanup:Cancel()
            end

            scheduledCleanup = C_Timer.NewTimer(RCPT_Config.pullDuration + 1, function()
                Debug("Pull timer expired, cleaning up chat listeners.")
                UnregisterChatEvents()
                scheduledCleanup = nil
                initiatedByMe = false
            end)
        else
            Debug("Not everyone is ready")
            if RCPT_Config.retryTimeout and retryCount < RCPT_Config.maxRetries then
                retryCount = retryCount + 1
                C_Timer.After(RCPT_Config.retryTimeout, function()
                    DoReadyCheck()
                end)
            else
                Debug("Max retries reached")
                UnregisterChatEvents()
                initiatedByMe = false
            end
        end

    elseif event:match("^CHAT_MSG_") then
        Debug("Chat message received: " .. event)
        local msg = select(1, ...)
        msg = msg:lower()
        for _, keyword in ipairs(RCPT_Config.cancelKeywords) do
            if msg:match(keyword) then
                Debug("Cancel keyword detected: " .. keyword)
                CancelPullTimer()
                break
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
    _G.RCPT_MainActive = true
end

-- expose initializer for manager to re-attach after teardown
_G.RCPT_Initialize = InitModule

-- call at load-time
InitModule()

-- Teardown: unregister events and stop timers so the addon can be effectively disabled
local function Teardown()
    f:UnregisterEvent("READY_CHECK")
    f:UnregisterEvent("READY_CHECK_CONFIRM")
    f:UnregisterEvent("READY_CHECK_FINISHED")
    UnregisterChatEvents()
    if scheduledCleanup then
        pcall(function() scheduledCleanup:Cancel() end)
        scheduledCleanup = nil
    end
    retryCount = 0
    initiatedByMe = false
    readyMap = {}
    Debug("|cff00ccff[RCPT]|r PullTimers module torn down.")
end

_G.RCPT_Teardown = Teardown
-- mark inactive when torn down
local oldTeardown = _G.RCPT_Teardown
_G.RCPT_Teardown = function(...)
    if oldTeardown then pcall(oldTeardown, ...) end
    _G.RCPT_MainActive = false
end
