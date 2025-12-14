-- RCPT-PullTimers-Slash.lua
-- Slash command handlers for the PullTimers module.

-- Local debug helper (delegates to global if present)
local function Debug(msg)
    if _G.RCPT_Debug then
        _G.RCPT_Debug(msg)
    end
end

-- Public-facing commands (kept as globals for backward compatibility)
function RCPT_ToggleQuiet()
    RCPT_Config.debug = not RCPT_Config.debug
    if RCPT_Config.debug then
        print("|cff00ccff[RCPT]|r Verbose mode |cff00ff00ENABLED|r.")
    else
        print("|cff00ccff[RCPT]|r Verbose mode |cffff0000DISABLED|r. Addon will run silently.")
    end
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
        Debug("TalentCheck config value must be numeric.")
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

