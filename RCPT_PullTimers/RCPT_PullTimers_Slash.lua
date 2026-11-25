-- RCPT_PullTimers_Slash.lua
-- Slash command handlers for the PullTimers module.

-- Public-facing commands (kept as globals for backward compatibility)
-- The saved table is looked up on every call (never captured at load), so a
-- replaced RCPT_Config is always the one read and written.
local function GetDB()
    if type(RCPT_Config) == "table" then return RCPT_Config end
    local addon = _G.RCPT
    if addon and type(addon.db) == "table" then return addon.db end
    RCPT_Config = {}
    return RCPT_Config
end

local function SyncDB(DB)
    RCPT_Config = DB
    if _G.RCPT then _G.RCPT.db = DB end
end

local function RefreshOptions()
    if _G.RCPT_Options and _G.RCPT_Options.Refresh then _G.RCPT_Options.Refresh() end
end

function RCPT_ToggleQuiet()
    local DB = GetDB()
    DB.debug = not DB.debug
    if DB.debug then
        print("|cff00ccff[RCPT]|r Verbose mode |cff00ff00ENABLED|r.")
    else
        print("|cff00ccff[RCPT]|r Verbose mode |cffff0000DISABLED|r. Addon will run silently.")
    end
    -- keep global in sync for older code
    SyncDB(DB)
    RefreshOptions()
end

function RCPT_PrintHelp()
    local DB = GetDB()
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
    print(" /rcpt quiet               \226\134\146 Toggle debug (verbose) logging on/off")
    print(" /rcpt options             \226\134\146 Open the options panel (also: config, opt)")
    print(" /rcpt preview             \226\134\146 Preview the pull status frame (sends nothing)")
    print(" /rcpt rapid               \226\134\146 Toggle rapid mode session")
    print(" /rcpt rapid skip [sec]    \226\134\146 Skip to T-N seconds, 15-45 (default: " .. tostring(DB.rapidModeSkipTo or 30) .. ")")
    print(" /rcpt rapid add <sec>     \226\134\146 Lengthen (or shorten, negative) the running countdown, 15-360")
    print(" /rcpt rapid defer         \226\134\146 Defer current rapid mode pull")
    print(" /rcpt rapid restart       \226\134\146 Restart from deferred state")
    print(" /rcpt rapid stop          \226\134\146 End the rapid mode session")
    print(" /rcpt rapid report        \226\134\146 Print session report locally")
    print(" /rcpt rapid report raid   \226\134\146 Post session report to /raid")
    print(" /rcpt cooldowns           \226\134\146 Print your cooldown scan and received reports (testing)")
end

-- /rcpt cooldowns: own scan (Describe + each entry) and the received reports table.
local function PrintCooldowns()
    local addon = _G.RCPT
    local cd = addon and addon.Cooldowns
    if not (cd and cd.Scan) then
        print("|cffff0000[RCPT]|r Cooldown scanner is not loaded.")
    else
        local okC, canRead, why = true, true, nil
        if cd.CanRead then okC, canRead, why = pcall(cd.CanRead) end
        print("|cff00ccff[RCPT]|r Cooldowns readable: " .. tostring(okC and canRead) .. (why and (" (" .. tostring(why) .. ")") or ""))
        local ok, res, reason = pcall(cd.Scan)
        if not ok or type(res) ~= "table" then
            print("  Scan: no result (" .. tostring(ok and reason or res) .. ")")
        else
            local okD, text = pcall(cd.Describe, res)
            print("  Longest: " .. tostring(okD and text or "?"))
            for i, e in ipairs(res.list or {}) do
                print(string.format("  %d. %s  %.1fs left of %.0fs", i, tostring(e.name or e.spellID or e.itemID),
                    tonumber(e.remaining) or 0, tonumber(e.duration) or 0))
            end
        end
    end
    local comms = addon and addon.Comms
    if not (comms and comms.GetReports) then
        print("  Reports: comms not loaded.")
        return
    end
    local any = false
    for sender, r in pairs(comms.GetReports()) do
        any = true
        print(string.format("  Report %s: %.1fs (spell %s)", sender, r.remaining, tostring(r.spellID)))
    end
    if not any then print("  Reports: none.") end
    if _G.RCPT_RapidMode_ComputeDuration then
        local okP, duration, info = pcall(_G.RCPT_RapidMode_ComputeDuration)
        if okP and type(info) == "table" then
            print(string.format("  Rapid countdown now: %ds (base %ds%s)", duration, info.base or 0,
                info.reason and (", " .. info.reason) or ""))
        end
    end
end

function RCPT_SetConfig(key, value)
    local num = tonumber(value)
    if not num then
        print("|cffff0000[RCPT]|r Config value must be a number: " .. tostring(value))
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

    local DB = GetDB()
    DB[normalizedKey] = num
    SyncDB(DB)
    print("|cff00ccff[RCPT]|r Set " .. normalizedKey .. " = " .. num)
    RefreshOptions()
end

function RCPT_AddKeyword(word)
    local DB = GetDB()
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
    SyncDB(DB)
    print("|cff00ccff[RCPT]|r Added keyword: " .. word)
    RefreshOptions()
end

function RCPT_ResetConfig()
    RCPT_Config = nil
    if _G.RCPT then _G.RCPT.db = nil end
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
    elseif command == "options" or command == "config" or command == "opt" then
        if _G.RCPT_Options and _G.RCPT_Options.Open then _G.RCPT_Options.Open() end
    elseif command == "preview" then
        local addon = _G.RCPT
        if addon and type(addon.PreviewPullFrame) == "function" then
            addon.PreviewPullFrame()
        end
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
                    local started, reason = _G.RCPT_RapidMode_Start()
                    if started or (_G.RCPT_RapidMode_IsActive and _G.RCPT_RapidMode_IsActive()) then
                        print("|cff00ccff[RCPT]|r Rapid mode |cff00ff00STARTED|r.")
                    else
                        print("|cffff0000[RCPT]|r Rapid mode could not start: " .. tostring(reason or "unknown reason."))
                    end
                end
            end
        elseif subCmd == "skip" then
            local sec = tonumber(args[3])
            if _G.RCPT_RapidMode_Skip then
                _G.RCPT_RapidMode_Skip(sec)
            end
        elseif subCmd == "add" then
            local sec = tonumber(args[3])
            if not sec then
                print("|cffff0000[RCPT]|r Usage: /rcpt rapid add <seconds> (negative shortens).")
            elseif _G.RCPT_RapidMode_Adjust then
                local ok, reason = _G.RCPT_RapidMode_Adjust(sec)
                if not ok then print("|cffff0000[RCPT]|r Not adjusted: " .. tostring(reason or "unknown reason.")) end
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
        elseif subCmd == "report" then
            local target = args[3] and args[3]:lower() or nil
            if target == "raid" or target == "r" then
                if _G.RCPT_RapidMode_PostSessionReport then
                    _G.RCPT_RapidMode_PostSessionReport()
                end
            else
                if _G.RCPT_RapidMode_PrintSessionReport then
                    _G.RCPT_RapidMode_PrintSessionReport()
                end
            end
        else
            print("|cffff0000[RCPT]|r Unknown rapid subcommand. Use `/rcpt help`.")
        end
    elseif command == "cooldowns" or command == "cds" then
        PrintCooldowns()
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

-- One-time Rapid Mode discovery hint (once per account, RCPT_Config.rapidHintShown).
-- Armed by a ready check this player sent outside Rapid Mode (RC_SENT is only fired
-- for self-initiated checks); shown when that sequence ends: pull finished
-- (CYCLE_COMPLETE), pull cancelled, or ready check failed for good.
do
    local armed = false

    local function HintPending()
        return not (type(RCPT_Config) == "table" and RCPT_Config.rapidHintShown)
    end

    local function RapidActive()
        return _G.RCPT_RapidMode_IsActive and _G.RCPT_RapidMode_IsActive() == true
    end

    local function IsLeadOrAssist()
        return (UnitIsGroupLeader and UnitIsGroupLeader("player"))
            or (UnitIsGroupAssistant and UnitIsGroupAssistant("player")) or false
    end

    local function OnSequenceStart()
        if HintPending() and not RapidActive() then armed = true end
    end

    local function OnSequenceEnd()
        if not armed then return end
        armed = false
        if not HintPending() or RapidActive() or not IsLeadOrAssist() then return end
        GetDB().rapidHintShown = true
        local msg = "Tip: wiping repeatedly? Rapid Mode chains pull timers and ready checks for you - /rcpt rapid or Options > RCPT."
        local addon = _G.RCPT
        if addon and type(addon.Print) == "function" then addon.Print(msg) else print("|cff00ccff[RCPT]|r " .. msg) end
    end

    local register = _G.RCPT_PullTimers_RegisterCallback
    if type(register) == "function" then
        register("RC_SENT", OnSequenceStart)
        register("CYCLE_COMPLETE", OnSequenceEnd)
        register("PULL_CANCELLED", OnSequenceEnd)
        register("RC_FAILED_FINAL", OnSequenceEnd)
    end
end

