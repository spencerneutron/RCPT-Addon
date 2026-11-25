-- RCPT_PullTimers_Cooldowns.lua
-- Reads which of the player's OWN cooldowns are still running, so Rapid Mode can
-- lengthen the pull timer after a wipe to cover the longest one.
--
-- Premise (user): cooldowns of 90 s or less are not reset when an encounter
-- ends; a 50 s timer is too short when a 90 s cooldown has 80 s left.
--
-- Secret-safety rule (12.x): C_Spell.GetSpellCooldown / GetSpellCharges return
-- secret values while combat, encounter, challenge-mode or PvP restrictions are
-- active. CanRead() checks those predicates first, so the normal path never sees
-- a secret. Even so, every value from a cooldown API goes through IsSecret()
-- BEFORE any comparison, arithmetic, concatenation, tostring or table-key use;
-- a secret skips that entry. Every Blizzard call is wrapped in pcall and Scan
-- never raises.
--
-- API: Cooldowns.CanRead() -> ok, reason
--      Cooldowns.Scan(opts) -> result | nil, reason
--      Cooldowns.Describe(result) -> string

local Addon = _G.RCPT
if type(Addon) ~= "table" then return end

local Cooldowns = {}
Addon.Cooldowns = Cooldowns

local TRINKET_SLOTS = { 13, 14 }       -- INVSLOT_TRINKET1 / INVSLOT_TRINKET2
local MIN_GLOBAL_RECOVERY_TIME = 0.75 -- same threshold as Blizzard_CooldownViewer
local MAX_TOLERANCE = 2
local MIN_REMAINING = 1

local function Debug(msg)
    if Addon.Debug then pcall(Addon.Debug, "Cooldowns: " .. msg) end
end

-- True when v is a secret value (or a table whose accesses produce secrets).
local function IsSecret(v)
    if v == nil then return false end
    if issecretvalue then
        local ok, s = pcall(issecretvalue, v)
        if not ok or s then return true end
    end
    if type(v) == "table" and issecrettable then
        local ok, s = pcall(issecrettable, v)
        if not ok or s then return true end
    end
    return false
end

-- pcall wrapper returning only the first result (nil on error).
local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

-- Like Try, for display data (names, icons, item IDs): a secret result becomes nil.
local function Plain(fn, ...)
    local v = Try(fn, ...)
    if IsSecret(v) then return nil end
    return v
end

local RESTRICTION_TYPES = { "Combat", "Encounter", "ChallengeMode", "PvPMatch" }

function Cooldowns.CanRead()
    local RA = C_RestrictedActions
    local types = Enum and Enum.AddOnRestrictionType
    if RA and RA.IsAddOnRestrictionActive and types then
        for _, key in ipairs(RESTRICTION_TYPES) do
            local t = types[key]
            if t ~= nil then
                local ok, active = pcall(RA.IsAddOnRestrictionActive, t)
                if not ok or IsSecret(active) then return false, "restricted" end
                if active then return false, "restricted: " .. key end
            end
        end
    end
    if C_Secrets and C_Secrets.ShouldCooldownsBeSecret then
        local ok, secret = pcall(C_Secrets.ShouldCooldownsBeSecret)
        if not ok or IsSecret(secret) or secret then return false, "restricted: secret cooldowns" end
    end
    if InCombatLockdown then
        local ok, inCombat = pcall(InCombatLockdown)
        if not ok or IsSecret(inCombat) or inCombat then return false, "restricted: combat" end
    end
    return true
end

-- Returns remaining, duration for a spell, or nil. Charge spells count only at
-- zero charges, using the time to the next charge (Blizzard's viewer gives the
-- charge cooldown precedence while charges remain, then the spell cooldown).
local function ReadSpell(spellID, now, minD, maxD)
    if C_Secrets and C_Secrets.ShouldSpellCooldownBeSecret then
        local s = Try(C_Secrets.ShouldSpellCooldownBeSecret, spellID)
        if IsSecret(s) or s then return nil, true end -- always-secret spell, or restricted
    end
    local start, duration
    local charges = C_Spell.GetSpellCharges and Try(C_Spell.GetSpellCharges, spellID)
    if IsSecret(charges) then return nil, true end
    if type(charges) == "table" then
        local cur, maxC = charges.currentCharges, charges.maxCharges
        if IsSecret(cur) or IsSecret(maxC) then return nil, true end
        if type(maxC) == "number" and maxC > 1 then
            if type(cur) ~= "number" or cur > 0 then return nil end
            start, duration = charges.cooldownStartTime, charges.cooldownDuration
        end
    end
    if start == nil then
        local info = C_Spell.GetSpellCooldown and Try(C_Spell.GetSpellCooldown, spellID)
        if IsSecret(info) then return nil, true end
        if type(info) ~= "table" then return nil end
        if info.isEnabled == false or info.isOnGCD then return nil end -- never secret
        start, duration = info.startTime, info.duration
    end
    if IsSecret(start) or IsSecret(duration) then return nil, true end
    if type(start) ~= "number" or type(duration) ~= "number" then return nil end
    if duration <= MIN_GLOBAL_RECOVERY_TIME or start <= 0 then return nil end
    if duration < minD or duration > maxD then return nil end
    -- Wall-clock end = start + duration, as Blizzard_CooldownViewer computes it
    -- (it never scales by modRate; no Blizzard Lua does arithmetic on modRate).
    local remaining = start + duration - now
    if remaining <= MIN_REMAINING then return nil end
    return remaining, duration
end

local function ReadTrinket(slot, now, minD, maxD)
    if not GetInventoryItemCooldown then return nil end
    local ok, start, duration, enable, isOnGCD = pcall(GetInventoryItemCooldown, "player", slot)
    if not ok then return nil end
    if IsSecret(start) or IsSecret(duration) or IsSecret(enable) or IsSecret(isOnGCD) then return nil, true end
    if isOnGCD or not (enable == 1 or enable == true) then return nil end
    if type(start) ~= "number" or type(duration) ~= "number" then return nil end
    if duration <= MIN_GLOBAL_RECOVERY_TIME or start <= 0 then return nil end
    if duration < minD or duration > maxD then return nil end
    local remaining = start + duration - now
    if remaining <= MIN_REMAINING then return nil end
    return remaining, duration
end

-- Known spell IDs from the Essential and Utility Cooldown Viewer sets, resolved
-- like CooldownViewerItemDataMixin:GetSpellID (override, else base).
local function CollectSpells()
    local CV = C_CooldownViewer
    local cats = Enum and Enum.CooldownViewerCategory
    if not (CV and CV.GetCooldownViewerCategorySet and CV.GetCooldownViewerCooldownInfo and cats) then
        return {}, "cooldown viewer unavailable"
    end
    local out, seen = {}, {}
    for _, key in ipairs({ "Essential", "Utility" }) do
        local ids = cats[key] ~= nil and Try(CV.GetCooldownViewerCategorySet, cats[key]) or nil
        if type(ids) == "table" and not IsSecret(ids) then
            for _, cdID in ipairs(ids) do
                local info = not IsSecret(cdID) and Try(CV.GetCooldownViewerCooldownInfo, cdID) or nil
                if type(info) == "table" and not IsSecret(info) then
                    local known, slot = info.isKnown, info.equipSlot
                    local base, override = info.spellID, info.overrideSpellID
                    if not (IsSecret(known) or IsSecret(slot) or IsSecret(base) or IsSecret(override))
                        and known == true and slot == nil then
                        local id = override or base
                        if type(id) == "number" and not seen[id] and not (base and seen[base]) then
                            seen[id] = true
                            if base then seen[base] = true end
                            out[#out + 1] = id
                        end
                    end
                end
            end
        end
    end
    if #out == 0 then return out, "no cooldowns in viewer sets" end
    return out
end

local function DoScan(opts)
    opts = type(opts) == "table" and opts or {}
    local minD = tonumber(opts.minDuration) or 30
    local maxD = (tonumber(opts.maxDuration) or 90) + MAX_TOLERANCE

    local canRead, why = Cooldowns.CanRead()
    if not canRead then return nil, why or "restricted" end
    if not (C_Spell and GetTime) then return nil, "spell API unavailable" end
    local now = GetTime()

    local list, skipped = {}, 0
    local spells, reason = CollectSpells()
    for _, spellID in ipairs(spells) do
        local remaining, durOrSecret = ReadSpell(spellID, now, minD, maxD)
        if remaining then
            list[#list + 1] = {
                spellID = spellID, remaining = remaining, duration = durOrSecret,
                name = Plain(C_Spell.GetSpellName, spellID), icon = Plain(C_Spell.GetSpellTexture, spellID),
            }
        elseif durOrSecret == true then
            skipped = skipped + 1
        end
    end
    for _, slot in ipairs(TRINKET_SLOTS) do
        local remaining, durOrSecret = ReadTrinket(slot, now, minD, maxD)
        if remaining then
            local itemID = Plain(GetInventoryItemID, "player", slot)
            local name, icon
            if itemID and C_Item then
                name = Plain(C_Item.GetItemNameByID, itemID)
                icon = Plain(C_Item.GetItemIconByID, itemID)
            end
            list[#list + 1] = {
                itemID = itemID, remaining = remaining, duration = durOrSecret,
                name = name or ("Trinket " .. slot), icon = icon,
            }
        elseif durOrSecret == true then
            skipped = skipped + 1
        end
    end

    table.sort(list, function(a, b) return a.remaining > b.remaining end)
    local top = list[1]
    if skipped > 0 then Debug(skipped .. " entries skipped (secret)") end
    return {
        remaining = top and top.remaining or 0,
        spellID = top and top.spellID or nil,
        itemID = top and top.itemID or nil,
        name = top and top.name or nil,
        icon = top and top.icon or nil,
        list = list,
        skipped = skipped,
        reason = reason,
    }
end

function Cooldowns.Scan(opts)
    local ok, result, reason = pcall(DoScan, opts)
    if not ok then
        Debug("scan failed: " .. tostring(result))
        return nil, "error"
    end
    return result, reason
end

function Cooldowns.Describe(result)
    if type(result) ~= "table" or type(result.list) ~= "table" or #result.list == 0 then
        return "none"
    end
    local top = result.list[1]
    local name = type(top.name) == "string" and top.name or "?"
    return string.format("%s %ds", name, math.floor((tonumber(top.remaining) or 0) + 0.5))
end
