-- RCPT_PullTimers_Slash.lua
-- Slash command handlers for the PullTimers module.

-- Local debug helper (delegates to global if present)
local function Debug(msg)
    if _G.RCPT_Debug then
        _G.RCPT_Debug(msg)
    end
end

-- Public-facing commands (kept as globals for backward compatibility)
local Addon = _G.RCPT
local DB = (Addon and Addon.db) or RCPT_Config

function RCPT_ToggleQuiet()
    DB.debug = not DB.debug
    if DB.debug then
        print("|cff00ccff[RCPT]|r Verbose mode |cff00ff00ENABLED|r.")
    else
        print("|cff00ccff[RCPT]|r Verbose mode |cffff0000DISABLED|r. Addon will run silently.")
    end
    -- keep global in sync for older code
    RCPT_Config = DB
    if Addon then Addon.db = DB end
end

function RCPT_PrintHelp()
    print("|cff00ccff[RCPT Config Help]|r")
    print(" pullDuration = " .. tostring(DB.pullDuration))
    print(" retryTimeout = " .. tostring(DB.retryTimeout))
    print(" maxRetries = " .. tostring(DB.maxRetries))
    print(" cancelKeywords = {" .. table.concat(DB.cancelKeywords or {}, ", ") .. "}")
    print(" rapidModeDuration = " .. tostring(DB.rapidModeDuration))
    print(" rapidModeSkipTo = " .. tostring(DB.rapidModeSkipTo))
    print(" ")
    print(" /rcpt                      \226\134\146 Starts ready check")
    print(" /rcpt set <key> <value>   \226\134\146 Set numeric config")
    print(" /rcpt addkeyword <word>   \226\134\146 Add a cancel keyword (max 10)")
    print(" /rcpt reset               \226\134\146 Reset config to defaults")
    print(" /rcpt quiet               \226\134\146 Toggle addon chat messages on/off")
    print(" /rcpt rapid               \226\134\146 Toggle rapid mode session")
    print(" /rcpt rapid skip [sec]    \226\134\146 Skip to T-N seconds (default: " .. tostring(DB.rapidModeSkipTo or 30) .. ")")
    print(" /rcpt rapid defer         \226\134\146 Defer current rapid mode pull")
    print(" /rcpt rapid restart       \226\134\146 Restart from deferred state")
end

function RCPT_SetConfig(key, value)
    local num = tonumber(value)
    if not num then
        Debug("TalentCheck config value must be numeric.")
        return
    end

    local normalizedKeys = {
        pullduration = "pullDuration",
        retrytimeout = "retryTimeout",
        maxretries = "maxRetries",
        rapidmodeduration = "rapidModeDuration",
        rapidmodeskipto = "rapidModeSkipTo",
    }
    
    local normalizedKey = normalizedKeys[key:lower()]

    if not normalizedKey then
        print("|cffff0000[RCPT]|r Invalid key: " .. key)
        return
    end

    DB[normalizedKey] = num
    RCPT_Config = DB
    if Addon then Addon.db = DB end
    print("|cff00ccff[RCPT]|r Set " .. normalizedKey .. " = " .. num)
end

function RCPT_AddKeyword(word)
    DB.cancelKeywords = DB.cancelKeywords or {}
    for _, existing in ipairs(DB.cancelKeywords) do
        if existing == word then
            print("|cffffff00[RCPT]|r Keyword already exists.")
            return
        end
    end

    if #DB.cancelKeywords >= 10 then
        print("|cffff0000[RCPT]|r Maximum of 10 keywords reached.")
        return
    end

    table.insert(DB.cancelKeywords, word)
    RCPT_Config = DB
    if Addon then Addon.db = DB end
    print("|cff00ccff[RCPT]|r Added keyword: " .. word)
end

function RCPT_ResetConfig()
    RCPT_Config = nil
    if Addon then Addon.db = nil end
    ReloadUI()
end

-- Slash command registration
SLASH_RCPT1 = "/rcpt"

function SlashCmdList.RCPT(msg)
    local args = {}
    for word in msg:gmatch("%S+") do
        table.insert(args, word)
    end

    if #args == 0 then
        -- Call the public API exported by the runtime module
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
    elseif command == "rapid" then
        local subCmd = args[2] and args[2]:lower() or nil
        if not subCmd then
            -- Toggle rapid mode session
            if _G.RCPT_RapidMode_IsActive and _G.RCPT_RapidMode_IsActive() then
                if _G.RCPT_RapidMode_Stop then
                    _G.RCPT_RapidMode_Stop()
                    print("|cff00ccff[RCPT]|r Rapid mode |cffff0000STOPPED|r.")
                end
            else
                if _G.RCPT_RapidMode_Start then
                    _G.RCPT_RapidMode_Start()
                    print("|cff00ccff[RCPT]|r Rapid mode |cff00ff00STARTED|r.")
                end
            end
        elseif subCmd == "skip" then
            local sec = tonumber(args[3])
            if _G.RCPT_RapidMode_Skip then
                _G.RCPT_RapidMode_Skip(sec)
            end
        elseif subCmd == "defer" then
            if _G.RCPT_RapidMode_Defer then
                _G.RCPT_RapidMode_Defer()
            end
        elseif subCmd == "restart" then
            if _G.RCPT_RapidMode_Restart then
                _G.RCPT_RapidMode_Restart()
            end
        elseif subCmd == "stop" then
            if _G.RCPT_RapidMode_Stop then
                _G.RCPT_RapidMode_Stop()
                print("|cff00ccff[RCPT]|r Rapid mode |cffff0000STOPPED|r.")
            end
        else
            print("|cffff0000[RCPT]|r Unknown rapid subcommand. Use `/rcpt help`.")
        end
    else
        print("|cffff0000[RCPT]|r Unknown command. Use `/rcpt help`.")
    end
end

SLASH_RCPTHELP1 = "/rcpthelp"
function SlashCmdList.RCPTHELP()
    RCPT_PrintHelp()
end

-- Export legacy globals for compatibility (explicit)
_G.RCPT_ToggleQuiet = RCPT_ToggleQuiet
_G.RCPT_PrintHelp = RCPT_PrintHelp
_G.RCPT_SetConfig = RCPT_SetConfig
_G.RCPT_AddKeyword = RCPT_AddKeyword
_G.RCPT_ResetConfig = RCPT_ResetConfig

