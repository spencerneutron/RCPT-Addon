-- RCPT.lua
local f = CreateFrame("Frame")
local retryCount = 0
local readyMap = {}
local scheduledCleanup = nil

RCPT_InitDefaults()

local function Debug(msg)
    if RCPT_Config.debug then
        print("|cff00ccff[RCPT]|r " .. msg)
    else
        print("no debug")
    end
end

local function StartPullTimer(seconds)
    C_PartyInfo.DoCountdown(seconds)
end

local function CancelPullTimer()
    C_PartyInfo.DoCountdown(0)
end

f:RegisterEvent("READY_CHECK")
f:RegisterEvent("READY_CHECK_CONFIRM")
f:RegisterEvent("READY_CHECK_FINISHED")

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
end

function RCPT_SetConfig(key, value)
    local num = tonumber(value)
    if not num then
        print("|cffff0000[RCPT]|r Value must be numeric.")
        return
    end

    -- Normalize the key to match internal config naming
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
    else
        print("|cffff0000[RCPT]|r Unknown command. Use `/rcpt help`.")
    end
end

SLASH_RCPTHELP1 = "/rcpthelp"
function SlashCmdList.RCPTHELP()
    RCPT_PrintHelp()
end

f:SetScript("OnEvent", function(_, event, ...)
    if event == "READY_CHECK" then
        readyMap = {}

        local myUnit = UnitName("player")
        readyMap[myUnit] = true -- Add self to readiness map

        Debug("Ready check started")

    elseif event == "READY_CHECK_CONFIRM" then
        local unit, isReady = ...
        readyMap[unit] = isReady
        Debug(unit .. " is " .. (isReady and "READY" or "NOT ready"))

    elseif event == "READY_CHECK_FINISHED" then
        Debug("Ready check finished")
        local allReady = true
        for unit, isReady in pairs(readyMap) do
            if not isReady then
                allReady = false
                break
            end
        end

        if allReady and next(readyMap) ~= nil then
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
