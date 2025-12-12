-- RCPT-Main.lua
-- Main addon logic (load-on-demand). Assumes bootstrap loaded `config.lua` and SavedVariables.

local f = CreateFrame("Frame")
local retryCount = 0
local readyMap = {}
local scheduledCleanup = nil
local initiatedByMe = false

-- Ensure defaults/migration run if available
if RCPT_InitDefaults then
    pcall(RCPT_InitDefaults)
end

local function Debug(msg)
    if RCPT_Config and RCPT_Config.debug then
        print("|cff00ccff[RCPT]|r " .. msg)
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

function RCPT_ToggleQuiet()
    RCPT_Config.debug = not RCPT_Config.debug
    if RCPT_Config.debug then
        print("|cff00ccff[RCPT]|r Verbose mode |cff00ff00ENABLED|r.")
    else
        print("|cff00ccff[RCPT]|r Verbose mode |cffff0000DISABLED|r. Addon will run silently.")
    end
end

function RCPT_RunReadyCheck()
    retryCount = 0
    RegisterChatEvents()
    readyMap = {}

    local me = UnitFullName("player")
    readyMap[me] = true

    DoReadyCheck()
end

function RCPT_PrintHelp()
    print("|cff00ccff[RCPT Config Help]|r")
    print(" pullDuration = " .. tostring(RCPT_Config.pullDuration))
    print(" retryTimeout = " .. tostring(RCPT_Config.retryTimeout))
    print(" maxRetries = " .. tostring(RCPT_Config.maxRetries))
    print(" cancelKeywords = {" .. table.concat(RCPT_Config.cancelKeywords, ", ") .. "}")
    print(" ")
    print(" /rcpt                      → Starts ready check")
    print(" /rcpt set <key> <value>   → Set numeric config")
    print(" /rcpt addkeyword <word>   → Add a cancel keyword (max 10)")
    print(" /rcpt reset               → Reset config to defaults")
    print(" /rcpt quiet               → Toggle addon chat messages on/off")
end

function RCPT_SetConfig(key, value)
    local num = tonumber(value)
    if not num then
        print("|cffff0000[RCPT]|r Value must be numeric.")
        return
    end

    local normalizedKeys = {
        pullduration = "pullDuration",
        retrytimeout = "retryTimeout",
        maxretries = "maxRetries"
    }
    
    local normalizedKey = normalizedKeys[key:lower()]

    if not normalizedKey then
        print("|cffff0000[RCPT]|r Invalid key: " .. key)
        return
    end

    RCPT_Config[normalizedKey] = num
    print("|cff00ccff[RCPT]|r Set " .. normalizedKey .. " = " .. num)
end

function RCPT_AddKeyword(word)
    for _, existing in ipairs(RCPT_Config.cancelKeywords) do
        if existing == word then
            print("|cffffff00[RCPT]|r Keyword already exists.")
            return
        end
    end

    if #RCPT_Config.cancelKeywords >= 10 then
        print("|cffff0000[RCPT]|r Maximum of 10 keywords reached.")
        return
    end

    table.insert(RCPT_Config.cancelKeywords, word)
    print("|cff00ccff[RCPT]|r Added keyword: " .. word)
end

function RCPT_ResetConfig()
    RCPT_Config = nil
    ReloadUI()
end

-- Slash commands
SLASH_RCPT1 = "/rcpt"

function SlashCmdList.RCPT(msg)
    local args = {}
    for word in msg:gmatch("%S+") do
        table.insert(args, word)
    end

    if #args == 0 then
        RCPT_RunReadyCheck()
        return
    end

    local command = args[1]:lower()

    if command == "help" then
        RCPT_PrintHelp()
    elseif command == "set" and args[2] and args[3] then
        RCPT_SetConfig(args[2]:lower(), args[3])
    elseif command == "addkeyword" and args[2] then
        RCPT_AddKeyword(args[2]:lower())
    elseif command == "reset" then
        RCPT_ResetConfig()
    elseif command == "quiet" then
        RCPT_ToggleQuiet()
    else
        print("|cffff0000[RCPT]|r Unknown command. Use `/rcpt help`.")
    end
end

SLASH_RCPTHELP1 = "/rcpthelp"
function SlashCmdList.RCPTHELP()
    RCPT_PrintHelp()
end

-- Event handler registration occurs when the addon loads
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

        for i = 1, GetNumGroupMembers() do
            local name, rank, subgroup, level, class, fileName, zone, online = GetRaidRosterInfo(i)
            if online then
                local fullName = name
                if readyMap[fullName] ~= true then
                    allReady = false
                    Debug("Missing or not ready: " .. fullName)
                    break
                end
            end
        end

        if allReady then
            Debug("Everyone is ready, starting pull timer")
            StartPullTimer(RCPT_Config.pullDuration)
            
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

-- Register only the core ready-check events when loaded
f:RegisterEvent("READY_CHECK")
f:RegisterEvent("READY_CHECK_CONFIRM")
f:RegisterEvent("READY_CHECK_FINISHED")

-- Provide a helper for loading the TalentCheck module on demand
function RCPT_LoadTalentModule()
    if not IsAddOnLoaded("RCPT-TalentCheck") then
        local ok, reason = LoadAddOn("RCPT-TalentCheck")
        if not ok then
            Debug("Failed to load TalentCheck module: " .. tostring(reason))
        end
    end
end

-- When the main addon loads, ensure defaults are in place and connect to Options if available
if IsLoggedIn and IsLoggedIn() then
    if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
end

-- Teardown: unregister events and stop timers so the addon can be effectively disabled
local function Teardown()
    -- Unregister main runtime events
    f:UnregisterEvent("READY_CHECK")
    f:UnregisterEvent("READY_CHECK_CONFIRM")
    f:UnregisterEvent("READY_CHECK_FINISHED")
    -- Unregister chat listeners if registered
    UnregisterChatEvents()
    -- Cancel scheduled cleanup timer if present
    if scheduledCleanup then
        pcall(function() scheduledCleanup:Cancel() end)
        scheduledCleanup = nil
    end
    -- reset transient state
    retryCount = 0
    initiatedByMe = false
    readyMap = {}
    Debug("Teardown complete; main addon idle.")
end

-- Expose teardown globally for the bootstrap to call when leaving groups
_G.RCPT_Teardown = Teardown
