-- RCPT_PullTimers_Comms.lua
-- Raid-wide cooldown reports for the Rapid Mode dynamic timer.
--
-- After a wipe (ENCOUNTER_END success 0) every RCPT client scans its own
-- cooldowns (kept locally under its own key, PT reads it like a report) and,
-- with shareCooldowns on, sends ONE addon message, about 2-3.5 s later, with its own longest short
-- cooldown: "CD1:<remaining>:<spellID or 0>" on prefix "RCPT". Nothing else is
-- sent. The leader's Rapid Mode reads the longest report through
-- Comms.GetLongestReported(); a report that arrives during a running countdown
-- reaches PT through Comms.OnReport.
--
-- Receiver: reports are kept only for current group members, every payload
-- field is checked with issecretvalue before use, values are parsed with
-- tonumber and clamped 0-92, and the table is cleared at ENCOUNTER_START.
-- Never sends in combat, during an encounter or under chat-messaging lockdown;
-- any send failure is ignored.
--
-- API: Comms.Init(), Comms.Teardown()
--      Comms.GetLongestReported() -> remaining (0 when none), sender, spellID
--      Comms.GetReports() -> { [sender] = { remaining, spellID } } (decayed copy)
--      Comms.OnReport(sender, remaining, spellID) -- hook, set to PT's handler

local Addon = _G.RCPT
if type(Addon) ~= "table" then return end

local Comms = {}
Addon.Comms = Comms

local PREFIX = "RCPT"
local TAG = "CD1"
local MAX_REPORT = 92           -- 90 s cooldowns plus a small tolerance
local SEND_DELAY = 2
local SEND_JITTER = 1.5         -- spreads sends over 2-3.5 s
local SEND_RETRIES = 2          -- extra tries, 1 s apart, while cooldowns are unreadable
local VALID_CHANNELS = { RAID = true, PARTY = true, INSTANCE_CHAT = true }

local frame = CreateFrame("Frame")
local active = false
local prefixRegistered = false
local reports = {}              -- [normalised sender] = { expiresAt, spellID }
local sendTimer

local function Debug(msg)
    if Addon.Debug then pcall(Addon.Debug, "Comms: " .. msg) end
end

local function GetDB()
    return (type(Addon.db) == "table" and Addon.db) or (type(RCPT_Config) == "table" and RCPT_Config) or {}
end

local function IsSecret(v)
    if v == nil or not issecretvalue then return false end
    local ok, s = pcall(issecretvalue, v)
    return not ok or s == true
end

-- ---------------------------------------------------------------------------
-- Names: "Name-Realm" for everyone (same normalisation as PT's
-- MakeFullNameFromParts; an empty or missing realm becomes the player's realm,
-- so "Name" and "Name-Realm" from different sources compare equal).
-- ---------------------------------------------------------------------------
local function MyRealm()
    if GetNormalizedRealmName then
        local ok, realm = pcall(GetNormalizedRealmName)
        if ok and type(realm) == "string" and realm ~= "" and not IsSecret(realm) then return realm end
    end
    return nil
end

local function NormaliseName(name)
    if type(name) ~= "string" or name == "" or IsSecret(name) then return nil end
    if name:find("-", 1, true) then return name end
    local realm = MyRealm()
    return realm and (name .. "-" .. realm) or name
end

local function UnitKey(unit)
    if not UnitFullName then return nil end
    local ok, name, realm = pcall(UnitFullName, unit)
    if not ok or IsSecret(name) or IsSecret(realm) or type(name) ~= "string" then return nil end
    if type(realm) == "string" and realm ~= "" then return name .. "-" .. realm end
    return NormaliseName(name)
end

local function IsGroupMember(key)
    if not key then return false end
    local inRaid = IsInRaid()
    local n = GetNumGroupMembers() or 0
    for i = 1, n do
        local unit
        if inRaid then unit = "raid" .. i else unit = (i == 1) and "player" or ("party" .. (i - 1)) end
        if UnitKey(unit) == key then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------
local function GetChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function ChatLocked()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if not ok or IsSecret(locked) or locked then return true end
    end
    if InCombatLockdown then
        local ok, inCombat = pcall(InCombatLockdown)
        if not ok or IsSecret(inCombat) or inCombat then return true end
    end
    return false
end

local function CancelSend()
    if sendTimer then
        pcall(function() sendTimer:Cancel() end)
        sendTimer = nil
    end
end

-- Keeps a valid report (remote, or the player's own scan) and hands it to PT.
local function StoreReport(key, rem, spellID)
    reports[key] = { expiresAt = GetTime() + rem, spellID = spellID }
    Debug("report " .. key .. " " .. rem .. "s spell " .. spellID)
    if type(Comms.OnReport) == "function" then pcall(Comms.OnReport, key, rem, spellID) end
end

-- Scans the player's own cooldowns once readable, keeps the result locally under
-- the player's key (also with shareCooldowns off: own data needs no sharing; the
-- echo of the message is ignored), then sends it when sharing is on.
local function TrySend(triesLeft)
    sendTimer = nil
    if not active then return end
    local channel = GetChannel()
    if not channel then return end
    local cd = Addon.Cooldowns
    if not (cd and cd.Scan) then return end
    local share = GetDB().shareCooldowns ~= false and prefixRegistered
        and C_ChatInfo and C_ChatInfo.SendAddonMessage and true or false

    local okR, canRead = true, true
    if cd.CanRead then okR, canRead = pcall(cd.CanRead) end
    local blocked = not okR or not canRead or (share and ChatLocked())
    if blocked and triesLeft > 0 then
        sendTimer = C_Timer.NewTimer(1, function() TrySend(triesLeft - 1) end)
        if not okR or not canRead then return end
        -- Readable but chat locked: keep the own result now, send on the retry
        share = false
    elseif not okR or not canRead then
        Debug("not scanned: cooldowns restricted")
        return
    elseif blocked then
        Debug("not sent: chat restricted")
        share = false
    end

    local ok, res = pcall(cd.Scan)
    if not ok or type(res) ~= "table" then return end
    local selfKey = UnitKey("player")
    local rem = res.remaining
    if type(rem) ~= "number" or rem ~= rem or rem <= 0 then
        if selfKey then reports[selfKey] = nil end
        return
    end
    rem = math.min(math.floor(rem + 0.5), MAX_REPORT)
    if rem <= 0 then return end
    local spellID = (type(res.spellID) == "number" and res.spellID > 0) and math.floor(res.spellID) or 0
    if selfKey then StoreReport(selfKey, rem, spellID) end
    if not share then return end
    local msg = string.format("%s:%d:%d", TAG, rem, spellID)
    local okS, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel)
    Debug("sent " .. msg .. " on " .. channel .. " (" .. tostring(okS and result) .. ")")
end

local function ScheduleSend()
    CancelSend()
    -- Runs with shareCooldowns off too: TrySend still keeps the own scan locally
    local delay = SEND_DELAY + math.random() * SEND_JITTER
    sendTimer = C_Timer.NewTimer(delay, function() TrySend(SEND_RETRIES) end)
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------
local function OnAddonMessage(prefix, text, channel, sender)
    if IsSecret(prefix) or IsSecret(text) or IsSecret(channel) or IsSecret(sender) then return end
    if prefix ~= PREFIX or type(text) ~= "string" then return end
    if not VALID_CHANNELS[channel] then return end
    local tag, a, b = text:match("^(%w+):([^:]*):([^:]*)$")
    if tag ~= TAG then return end
    local rem, spellID = tonumber(a), tonumber(b)
    if not rem or rem ~= rem then return end
    if rem < 0 then rem = 0 end
    if rem > MAX_REPORT then rem = MAX_REPORT end
    if not spellID or spellID ~= spellID or spellID < 0 or spellID > 2147483647 then spellID = 0 end
    spellID = math.floor(spellID)

    local key = NormaliseName(sender)
    if not key or key == UnitKey("player") then return end -- own echo
    if not IsGroupMember(key) then
        Debug("ignored report from non-member " .. key)
        return
    end

    if rem <= 0 then
        reports[key] = nil
        return
    end
    StoreReport(key, rem, spellID)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
-- Skips (and removes) reports from players who have left the group; the
-- player's own entry always counts.
function Comms.GetLongestReported()
    local now = GetTime()
    local me = UnitKey("player")
    local bestRem, bestSender, bestSpell = 0, nil, nil
    for sender, r in pairs(reports) do
        local left = r.expiresAt - now
        if left <= 0 or (sender ~= me and not IsGroupMember(sender)) then
            reports[sender] = nil  -- clearing a field during pairs is allowed
        elseif left > bestRem then
            bestRem, bestSender, bestSpell = left, sender, r.spellID
        end
    end
    return bestRem, bestSender, bestSpell
end

function Comms.GetReports()
    local now, out = GetTime(), {}
    for sender, r in pairs(reports) do
        local left = r.expiresAt - now
        if left > 0 then out[sender] = { remaining = left, spellID = r.spellID } end
    end
    return out
end

-- PT's handler extends a running Rapid Mode countdown (PT loads before this file)
Comms.OnReport = function(sender, remaining, spellID)
    local fn = _G.RCPT_RapidMode_OnCooldownReport
    if type(fn) == "function" then fn(sender, remaining, spellID) end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "ENCOUNTER_START" then
        reports = {}
        CancelSend()
    elseif event == "ENCOUNTER_END" then
        local success = select(5, ...)
        if success ~= nil and not IsSecret(success) and success == 0 then ScheduleSend() end
    end
end)

function Comms.Init()
    if active then return end
    if not prefixRegistered and C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        local R = Enum and Enum.RegisterAddonMessagePrefixResult
        -- Success or DuplicatePrefix (already registered) both mean we receive it
        prefixRegistered = ok and (not R or result == R.Success or result == R.DuplicatePrefix)
    end
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("ENCOUNTER_START")
    frame:RegisterEvent("ENCOUNTER_END")
    active = true
end

function Comms.Teardown()
    frame:UnregisterEvent("CHAT_MSG_ADDON")
    frame:UnregisterEvent("ENCOUNTER_START")
    frame:UnregisterEvent("ENCOUNTER_END")
    CancelSend()
    reports = {}
    active = false
end

-- First load: initialise through the module registry like PT does
-- (PT's InitModule / Teardown call Comms.Init / Comms.Teardown on re-attach).
if type(Addon.RegisterModule) == "function" then
    Addon:RegisterModule("PullTimersComms", { Init = function() Comms.Init() end })
else
    Comms.Init()
end
