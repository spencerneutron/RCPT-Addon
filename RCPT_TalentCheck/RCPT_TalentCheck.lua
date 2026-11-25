-- RCPT_TalentCheck.lua
-- Ready-check overlay: spec, talent loadout and durability at a glance, a
-- durability gate on the Ready button (hold Ctrl to override), a compact
-- "mini" bar once the player has answered, and optional chat reports.
--
-- Origin: a WeakAura on READY_CHECK that checked equipment durability
-- (aura_env.CheckLowDurability) and offered a "Change Talents" button.
--
-- Built on the shared design system in RCPT/Style.lua (Addon.Style).

local addonName = "RCPT"

RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}

local Module = {}
local Addon = _G.RCPT
local Style = Addon and Addon.Style

-- Public export table: created at file load so every export below can be
-- assigned whatever path (RegisterModule or immediate init) loads the file.
local Exports = _G.RCPT_TalentCheck or {}
_G.RCPT_TalentCheck = Exports

local floor = math.floor

------------------------------------------------------------------------
-- Layout constants (px)
------------------------------------------------------------------------

local PANEL_W       = 380
local PAD           = 8                      -- gutter
local ACCENT_W      = 4                      -- 1px border + 3px accent strip
local CONTENT_L     = ACCENT_W + PAD         -- left content edge
local ICON          = 40
local ICON_GAP      = 10
local COLLAPSE_SIZE = 20
local DUR_RIGHT     = 4 + COLLAPSE_SIZE + 6  -- durability column keeps clear of the collapse button
local DUR_COL_W     = 80
local DUR_BAR_H     = 6
local DUR_ICON      = 12
local TEXT_W        = PANEL_W - CONTENT_L - ICON - ICON_GAP - DUR_COL_W - DUR_RIGHT - PAD   -- 200
local HEADER_H      = PAD + ICON + PAD       -- 56
local BANNER_H      = 26
local BANNER_ICON   = 18
local HELPER_H      = 18
local BUTTON_H      = 24
local BTN_W         = 90
local CHANGE_W      = 120
local EXPANDED_H    = HEADER_H + BUTTON_H + PAD   -- 88
local REPAIR_EXTRA  = BANNER_H + HELPER_H         -- banner row + helper row
local COLLAPSED_H   = 28

local MINI_W, MINI_H = 260, 28
local MINI_ICON      = 16
local MINI_DUR_W     = 52                     -- repair icon + "100%"
local MINI_LOADOUT_W = MINI_W - CONTENT_L - MINI_ICON - 6 - MINI_DUR_W - PAD - PAD

local FADE_IN, FADE_OUT   = 0.15, 0.2
local HOLD_SECONDS        = 1.5
local OVERRIDE_FREEZE     = 0.6
local OVERRIDE_REVOKE     = 4
local REFRESH_SECONDS     = 0.5
local AUTO_HIDE_SECONDS   = 30
local SIM_MINI_SECONDS    = 5
local WARN_MARGIN         = 10      -- durability within this many points above the threshold shows as "wait"

local UNKNOWN_SPEC    = "Unknown Spec"
local UNKNOWN_LOADOUT = "Unknown Loadout"
local FALLBACK_ICON   = "Interface\\Icons\\INV_Misc_QuestionMark"
local HELPER_HOLD     = "Hold Ctrl over Ready for 1.5s to ready anyway"
local HELPER_HOLDING  = "Keep holding Ctrl..."
local HELPER_ARMED    = "Override ready: click Ready"
local DOT             = " \194\183 "   -- " · " (UTF-8 middle dot)
-- Blizzard's merchant repair icon (MerchantFrame.xml, RepairItemButton)
local REPAIR_ATLAS    = "SpellIcon-256x256-Repair"
local MINI_DUR_MARKUP = "|A:" .. REPAIR_ATLAS .. ":12:12|a "

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------

local function RefreshAddon()
        Addon = _G.RCPT or Addon
        Style = (Addon and Addon.Style) or Style
end

local function DB()
        return (Addon and Addon.talentDB) or RCPT_TalentCheckDB or {}
end

-- Local debug wrapper that delegates to the global helper when available.
local function Debug(msg)
        if _G and _G.RCPT_Debug then
                _G.RCPT_Debug(msg)
        end
end

local function Threshold()
        local t = DB().MinDurabilityPercent
        if type(t) ~= "number" then t = 80 end
        return t
end

-- ReplaceReadyCheck: nil (never saved) counts as the default, true.
local function UseReplace()
        return DB().ReplaceReadyCheck ~= false
end

-- Secret values (12.x restrictions) cannot be compared, concatenated or used
-- in arithmetic by addon code. Treat anything we cannot inspect as secret.
-- issecretvalue is asked first, so a secret value is never compared (not even to nil).
local function IsSecret(v)
        local check = _G.issecretvalue
        if type(check) ~= "function" then return false end
        local ok, res = pcall(check, v)
        return (not ok) or res == true
end

-- True when `who` (unit token or player name) is the player. Never raises.
local function IsPlayer(who)
        if IsSecret(who) or who == nil then return false end
        if who == "player" then return true end
        local okn, pname = pcall(UnitName, "player")
        if okn and not IsSecret(pname) and pname ~= nil and who == pname then return true end
        local ok, res = pcall(function()
                if Addon and Addon.SafeUnitIsUnit then return Addon.SafeUnitIsUnit(who, "player") end
                return UnitIsUnit(who, "player") == true
        end)
        return ok and res == true
end

-- "ready" | "notready" | "waiting" | nil (no ready check, or unreadable).
local function PlayerReadyStatus()
        if type(GetReadyCheckStatus) ~= "function" then return nil end
        local ok, s = pcall(GetReadyCheckStatus, "player")
        if not ok or IsSecret(s) then return nil end
        if s == "ready" or s == "notready" or s == "waiting" then return s end
        return nil
end

local function SendChat(message, chatType, languageID, target)
        if C_ChatInfo and C_ChatInfo.SendChatMessage then
                C_ChatInfo.SendChatMessage(message, chatType, languageID, target)
        elseif _G.SendChatMessage then
                _G.SendChatMessage(message, chatType, languageID, target)
        end
end

-- Answer the real ready check through Blizzard's own buttons.
local function ClickDefault(ready)
        local btn = ready and _G.ReadyCheckFrameYesButton or _G.ReadyCheckFrameNoButton
        if btn and btn.Click then pcall(btn.Click, btn) end
end

-- Robust cursor-inside-frame check (independent of OnEnter/OnLeave).
local function CursorIsOverFrame(f)
        if not f or not f:IsVisible() then return false end
        local ok, over = pcall(f.IsMouseOver, f)
        return ok and over == true
end

------------------------------------------------------------------------
-- Tooltips
------------------------------------------------------------------------

local function HideTip(owner)
        if GameTooltip and GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
end

local function ShowTip(owner, title, text)
        if not GameTooltip or not title then return end
        GameTooltip:SetOwner(owner, "ANCHOR_TOP")
        GameTooltip:SetText(title, 1, 1, 1)
        if text and text ~= "" then
                local r, g, b = Style.Color("text")
                GameTooltip:AddLine(text, r, g, b, true)
        end
        GameTooltip:Show()
end

-- Static tooltip through the shared Style helper (absent: no tooltip).
local function StaticTip(region, title, text)
        if Style and Style.SetTooltip then pcall(Style.SetTooltip, region, title, text) end
end

-- Tooltip whose content is computed on hover: getter(region) -> title, text.
-- Hooks (never replaces) OnEnter/OnLeave, so set any SetScript handlers first.
local function ShowDynamicTip(region, getter)
        local ok, title, text = pcall(getter, region)
        if ok and title then ShowTip(region, title, text) end
end

local function DynamicTip(region, getter)
        region:HookScript("OnEnter", function(self) ShowDynamicTip(self, getter) end)
        region:HookScript("OnLeave", HideTip)
end

-- Mouse-motion-only frame over a FontString/region (FontStrings take no mouse
-- events). Clicks and drags fall through to the panel underneath.
local function CreateHoverZone(parent, getter)
        local z = CreateFrame("Frame", nil, parent)
        z:EnableMouse(true)
        pcall(z.SetMouseClickEnabled, z, false)
        DynamicTip(z, getter)
        return z
end

------------------------------------------------------------------------
-- Positions, scale and dragging (shared frame settings live in RCPT_Config)
------------------------------------------------------------------------

-- Saved positions always go to the SavedVariables table itself.
local function PosDB()
        if type(RCPT_TalentCheckDB) ~= "table" then RCPT_TalentCheckDB = {} end
        return RCPT_TalentCheckDB
end

local function FrameScale()
        local c = _G.RCPT_Config
        local s = type(c) == "table" and c.frameScale or 1
        if type(s) ~= "number" or s ~= s then return 1 end
        if s < 0.5 then s = 0.5 elseif s > 2 then s = 2 end
        return s
end

local function FramesLocked()
        local c = _G.RCPT_Config
        return type(c) == "table" and c.lockFrames == true
end

-- true when a saved position was applied (and is on screen).
local function ApplySaved(f, pos)
        if type(pos) ~= "table" or not (Style and Style.ApplyPosition) then return false end
        local ok, res = pcall(Style.ApplyPosition, f, pos)
        return ok and res == true
end

local function SavePosition(f, key)
        if not (Style and Style.GetPosition) then return end
        local ok, pos = pcall(Style.GetPosition, f)
        if ok and type(pos) == "table" then
                PosDB()[key] = pos
                ApplySaved(f, pos)   -- re-anchor by TOP so later height changes grow downwards
        end
end

-- ApplySaved for PosDB()[key]; an older CENTER save is rewritten once in TOP
-- format so its top edge stops depending on the height at show time.
local function ApplySavedKey(f, key)
        local pos = PosDB()[key]
        if not ApplySaved(f, pos) then return false end
        if pos.point ~= "TOP" then SavePosition(f, key) end
        return true
end

-- Style.MakeMovable plus two gates read at drag start: the shared lock and
-- canDrag(frame). A refused drag never reaches the save in OnDragStop.
local function MakeDraggable(f, canDrag, onMoved)
        f:EnableMouse(true)
        if not (Style and Style.MakeMovable) then return end
        Style.MakeMovable(f, onMoved)
        local start, stop = f:GetScript("OnDragStart"), f:GetScript("OnDragStop")
        f:SetScript("OnDragStart", function(self, ...)
                if FramesLocked() or (canDrag and not canDrag(self)) then return end
                HideTip(self)
                self._rcptDragging = true
                if start then start(self, ...) end
        end)
        f:SetScript("OnDragStop", function(self, ...)
                if not self._rcptDragging then return end
                self._rcptDragging = nil
                if stop then stop(self, ...) end
        end)
        -- hidden mid-drag (session ended): finish the move so the frame never stays attached to the cursor
        f:HookScript("OnHide", function(self)
                if not self._rcptDragging then return end
                self._rcptDragging = nil
                if stop then pcall(stop, self) else pcall(self.StopMovingOrSizing, self) end
        end)
end

-- Saved positions apply only while the overlay replaces Blizzard's popup;
-- otherwise both frames sit above ReadyCheckFrame and stay put.
local function CanDrag() return UseReplace() end

------------------------------------------------------------------------
-- Data: durability, spec, loadout
------------------------------------------------------------------------

local function CheckLowDurability(threshold)
        threshold = threshold or Threshold()
        local numLowSlots = 0
        local totalDurability = 0
        local numSlotsWithDurability = 0

        for slot = 1, 17 do
                local current, maximum = GetInventoryItemDurability(slot)
                if current and maximum and maximum > 0 then
                        local durabilityPercent = (current / maximum) * 100
                        totalDurability = totalDurability + durabilityPercent
                        numSlotsWithDurability = numSlotsWithDurability + 1
                        if durabilityPercent < threshold then
                                numLowSlots = numLowSlots + 1
                        end
                end
        end

        local averageDurability = numSlotsWithDurability > 0 and (totalDurability / numSlotsWithDurability) or 100
        local isLow = numLowSlots > 0
        return isLow, numLowSlots, averageDurability
end

-- Colour token for the durability readout relative to the threshold.
local function DurabilityState(avg, isLow, threshold)
        if isLow or avg < threshold then return "fail" end
        if avg < threshold + WARN_MARGIN then return "wait" end
        return "ready"
end

-- Display only (tooltip): the most worn slot and its percentage, or nil.
local function LowestDurabilitySlot()
        local lowSlot, lowPct
        for slot = 1, 17 do
                local ok, current, maximum = pcall(GetInventoryItemDurability, slot)
                if ok and not IsSecret(current) and not IsSecret(maximum)
                        and type(current) == "number" and type(maximum) == "number" and maximum > 0 then
                        local pct = (current / maximum) * 100
                        if not lowPct or pct < lowPct then lowSlot, lowPct = slot, pct end
                end
        end
        return lowSlot, lowPct
end

-- Tooltip body for the durability readouts (overlay column and mini bar).
local function DurabilityTipText()
        local threshold = Threshold()
        local isLow, numLowSlots, avg = CheckLowDurability(threshold)
        local lines = { string.format("Average durability: %d%%", floor((avg or 100) + 0.5)) }
        local slot, pct = LowestDurabilitySlot()
        if slot then
                local okL, link = pcall(GetInventoryItemLink, "player", slot)
                if not okL or IsSecret(link) or type(link) ~= "string" then link = "slot " .. slot end
                lines[#lines + 1] = string.format("Lowest: %s %d%%", link, floor(pct + 0.5))
        end
        if isLow then
                lines[#lines + 1] = string.format("%d slot(s) below %d%%: Ready is blocked until you repair.", numLowSlots or 0, threshold)
        else
                lines[#lines + 1] = string.format("Ready is blocked below %d%% on any slot.", threshold)
        end
        return table.concat(lines, "\n")
end

local function GetCurrentLoadoutName()
        -- Check for Talent Loadout Ex (TLX) addon first
        local TLX = _G.TalentLoadoutEx
        if TLX and TLX.GetLoadedData then
                local okTLX, loadout = pcall(TLX.GetLoadedData)
                if okTLX and type(loadout) == "table" then
                        return "TLX: " .. tostring(loadout.name or "?")
                end
        end

        -- Default loadout retrieval via Blizzard API
        local got = false
        local loadoutName = UNKNOWN_LOADOUT

        if PlayerUtil and PlayerUtil.GetCurrentSpecID then
                local ok, specID = pcall(PlayerUtil.GetCurrentSpecID)
                if ok and specID and C_ClassTalents and C_ClassTalents.GetLastSelectedSavedConfigID and C_Traits and C_Traits.GetConfigInfo then
                        local ok2, configID = pcall(C_ClassTalents.GetLastSelectedSavedConfigID, specID)
                        if ok2 and configID then
                                local ok3, info = pcall(C_Traits.GetConfigInfo, configID)
                                if ok3 and info and info.name and info.name ~= "" then
                                        loadoutName = info.name
                                        got = true
                                end
                        end
                end
        end

        if not got and C_ClassTalents and C_ClassTalents.GetLastSelectedSavedConfigID then
                local ok, configID = pcall(C_ClassTalents.GetLastSelectedSavedConfigID, nil)
                if ok and configID and C_Traits and C_Traits.GetConfigInfo then
                        local ok2, info = pcall(C_Traits.GetConfigInfo, configID)
                        if ok2 and info and info.name and info.name ~= "" then
                                loadoutName = info.name
                        end
                end
        end

        return loadoutName
end

_G.RCPT_GetCurrentLoadoutName = GetCurrentLoadoutName

-- Returns specName, loadoutName, specIcon (fileID or nil).
local function GetSpecAndLoadout()
        local specName, specIcon = UNKNOWN_SPEC, nil

        local getSpec = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or _G.GetSpecialization
        local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or _G.GetSpecializationInfo
        if getSpec and getInfo then
                local ok, specIndex = pcall(getSpec)
                if ok and type(specIndex) == "number" and specIndex > 0 then
                        local ok2, _, name, _, icon = pcall(getInfo, specIndex)
                        if ok2 then
                                if type(name) == "string" and name ~= "" then specName = name end
                                specIcon = icon
                        end
                end
        end

        return specName, GetCurrentLoadoutName(), specIcon
end

_G.RCPT_GetSpecAndLoadout = GetSpecAndLoadout

local function FormatLoadout(name)
        if not name or name == UNKNOWN_LOADOUT then
                return Style.Colorize("textDim", "Unknown loadout")
        end
        return name
end

------------------------------------------------------------------------
-- Frames (created lazily on the first ready check)
------------------------------------------------------------------------

local frame = CreateFrame("Frame", addonName .. "TalentCheckFrame")
local overlay, mini = nil, nil
local restoringDefault = false  -- true while we re-show Blizzard's popup after a failed session start

local function RegisterOverlays()
        local core = _G.RCPT
        if not (core and core.RegisterOverlayFrame) then return end
        if overlay then pcall(core.RegisterOverlayFrame, core, "TalentCheckOverlay", overlay) end
        if mini then pcall(core.RegisterOverlayFrame, core, "TalentCheckMiniOverlay", mini) end
end

local function HideDefaultFrame()
        if not (overlay and ReadyCheckFrame and ReadyCheckFrame:IsShown()) then return end
        overlay._hidingDefault = true
        pcall(ReadyCheckFrame.Hide, ReadyCheckFrame)
        overlay._hidingDefault = nil
end

-- Put Blizzard's popup back (session start failed after it was hidden). The
-- flag keeps the OnShow hook from starting a new session from inside this call.
local function RestoreDefaultFrame()
        if not ReadyCheckFrame or ReadyCheckFrame:IsShown() then return end
        restoringDefault = true
        pcall(ReadyCheckFrame.Show, ReadyCheckFrame)
        restoringDefault = false
end

------------------------------------------------------------------------
-- Mini overlay
------------------------------------------------------------------------

local MINI_ACCENT = { ready = "ready", notready = "fail", waiting = "wait" }

-- Fill the mini overlay's status, durability and loadout.
local function PopulateMini(m)
        if not m then return end
        local state
        if m.simulated then
                state = m.fallbackState
        else
                local live = PlayerReadyStatus()
                state = ((live == "ready" or live == "notready") and live) or m.fallbackState or live
        end
        state = state or "waiting"

        m.statusIcon:SetAtlas(Style.StatusAtlas(state) or Style.StatusAtlas("waiting"))
        m:SetAccent(MINI_ACCENT[state] or "wait")
        m._state = state

        local threshold = Threshold()
        local isLow, _, avg = CheckLowDurability(threshold)
        m.durText:SetText(MINI_DUR_MARKUP .. string.format("%d%%", floor((avg or 100) + 0.5)))
        m.durText:SetTextColor(Style.Color(DurabilityState(avg or 100, isLow, threshold)))

        local _, loadoutName = GetSpecAndLoadout()
        m.loadoutText:SetText(loadoutName or UNKNOWN_LOADOUT)
        m._loadout = loadoutName or UNKNOWN_LOADOUT
end

local MINI_STATE_TEXT = { ready = "Ready", notready = "Not ready", waiting = "Waiting" }

local function MiniTip(m)
        local lines = {
                "Your answer: " .. (MINI_STATE_TEXT[m._state] or MINI_STATE_TEXT.waiting),
                "Loadout: " .. tostring(m._loadout or UNKNOWN_LOADOUT),
                DurabilityTipText(),
                " ",
                (CanDrag() and not FramesLocked()) and "Drag to move. Right-click to hide until the next ready check."
                        or "Right-click to hide until the next ready check.",
        }
        return "RCPT ready check", table.concat(lines, "\n")
end

local function CreateMiniOverlay()
        if mini then return mini end
        -- DIALOG, like Blizzard's ReadyCheckFrame: never behind the options panel (HIGH)
        local m = Style.CreatePanel(addonName .. "ReadyMiniOverlay", UIParent, {
                width = MINI_W, height = MINI_H, strata = "DIALOG", accent = "left",
        })
        m:SetScale(FrameScale())

        m.statusIcon = m:CreateTexture(nil, "ARTWORK")
        m.statusIcon:SetSize(MINI_ICON, MINI_ICON)
        m.statusIcon:SetPoint("LEFT", m, "LEFT", CONTENT_L, 0)

        m.durText = Style.CreateText(m, "body", "text")
        m.durText:SetPoint("LEFT", m.statusIcon, "RIGHT", 6, 0)
        m.durText:SetWidth(MINI_DUR_W)
        m.durText:SetJustifyH("LEFT")

        m.loadoutText = Style.CreateText(m, "small", "textDim")
        m.loadoutText:SetPoint("LEFT", m.durText, "RIGHT", PAD, 0)
        m.loadoutText:SetWidth(MINI_LOADOUT_W)
        m.loadoutText:SetJustifyH("LEFT")
        m.loadoutText:SetWordWrap(false)

        m.updateTicker = 0
        m:SetScript("OnShow", function(self) self.updateTicker = 0 end)
        m:SetScript("OnUpdate", function(self, elapsed)
                self.updateTicker = self.updateTicker + elapsed
                if self.updateTicker < REFRESH_SECONDS then return end
                self.updateTicker = 0
                pcall(PopulateMini, self)
        end)

        -- Drag to move (saved in RCPT_TalentCheckDB.miniPos); right-click hides
        -- it for the current ready check (ShowMini honours `dismissed`).
        MakeDraggable(m, CanDrag, function(self) SavePosition(self, "miniPos") end)
        m:SetScript("OnMouseUp", function(self, button)
                if button ~= "RightButton" then return end
                self.dismissed = true
                HideTip(self)
                Style.FadeOut(self, FADE_OUT)
        end)
        DynamicTip(m, MiniTip)

        -- Single source of truth for mini overlay visibility
        m.IsActiveOverlay = function(self) return self:IsShown() end
        m:Hide()

        mini = m
        RegisterOverlays()
        return m
end

local function PlaceMini(m)
        m:ClearAllPoints()
        if not UseReplace() and ReadyCheckFrame then
                -- 20px clears the popup's border art, which extends ~16px above the frame
                m:SetPoint("BOTTOM", ReadyCheckFrame, "TOP", 0, 20)
        elseif not ApplySavedKey(m, "miniPos") then
                -- default: upper screen, clear of the centre (it takes the mouse)
                m:SetPoint("TOP", UIParent, "TOP", 0, -140)
        end
end

-- Swap the main overlay for the mini bar (player answered, or initiated).
local function ShowMini(state)
        if not overlay then return end
        local m = CreateMiniOverlay()
        m.fallbackState = state
        m.simulated = overlay.simulated
        m:SetScale(FrameScale())
        PlaceMini(m)
        -- click-through in combat (world clicks, camera); PLAYER_REGEN_* toggles it after
        m:EnableMouse(not InCombatLockdown())
        overlay:CancelOverride()
        if overlay:IsShown() then
                -- hide the primary overlay but keep the session (watcher/timers) alive
                overlay._suppressOnHideClear = true
                overlay:Hide()
                overlay._suppressOnHideClear = nil
        end
        PopulateMini(m)
        if m.dismissed then return end   -- right-clicked away during this ready check
        Style.FadeIn(m, FADE_IN)
end

-- RCPT_Config.frameScale on the overlay, its Ready hitbox and the mini bar.
local function ApplyScale()
        local s = FrameScale()
        if overlay then
                overlay:SetScale(s)
                local hb = overlay.readyBtn and overlay.readyBtn.hitbox
                if hb then hb:SetScale(s) end
        end
        if mini then mini:SetScale(s) end
end

-- Addon.frameSettingListeners.talent: re-apply scale live and re-place shown
-- frames (saved positions are in UIParent coordinates, so they keep their spot).
local function OnFrameSettingsChanged()
        ApplyScale()
        if overlay and overlay:IsShown() then overlay:Place() end
        if mini and mini:IsShown() then PlaceMini(mini) end
end

-- Exported as RCPT_TalentCheck.ResetPositions: forget both saved positions and
-- move the frames back to their defaults. Works before creation and after teardown.
local function ResetPositions()
        local db = PosDB()
        db.overlayPos, db.miniPos = nil, nil
        if overlay then pcall(overlay.Place, overlay) end
        if mini then pcall(PlaceMini, mini) end
end

------------------------------------------------------------------------
-- Blizzard ReadyCheckFrame hooks
------------------------------------------------------------------------

local function OnDefaultShown()
        if restoringDefault or not overlay or not _G.RCPT_TalentActive then return end
        if overlay.sessionActive then
                if UseReplace() then HideDefaultFrame() elseif overlay:IsShown() then overlay:Place() end
                return
        end
        local ok, err = pcall(overlay.BeginSession, overlay, false, false)
        if not ok then Debug("RCPT: overlay error: " .. tostring(err)) end
end

local function OnDefaultHidden()
        if not overlay or overlay._hidingDefault then return end
        -- Blizzard closed its own popup (answered there, finished, group left):
        -- drop the main overlay but keep the session so READY_CHECK_CONFIRM can
        -- still show the mini bar and READY_CHECK_FINISHED can clean up.
        if overlay.sessionActive and overlay:IsShown() then
                overlay._suppressOnHideClear = true
                overlay:Hide()
                overlay._suppressOnHideClear = nil
        end
end

------------------------------------------------------------------------
-- Main overlay
------------------------------------------------------------------------

-- CreateReadyOverlay is split into per-section builders: Lua 5.1 caps a
-- function (with its nested closures) at 60 upvalues.

-- Header: spec icon, spec / loadout text, durability column, collapsed summary
local function BuildOverlayHeader(o)
        -- Header: spec icon with 1px black border, cropped edges
        o.iconBorder = o:CreateTexture(nil, "ARTWORK", nil, 0)
        o.iconBorder:SetColorTexture(Style.Color("border"))
        o.iconBorder:SetSize(ICON + 2, ICON + 2)
        o.iconBorder:SetPoint("TOPLEFT", o, "TOPLEFT", CONTENT_L - 1, -(PAD - 1))

        o.icon = o:CreateTexture(nil, "ARTWORK", nil, 1)
        o.icon:SetSize(ICON, ICON)
        o.icon:SetPoint("CENTER", o.iconBorder, "CENTER", 0, 0)
        o.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        o.icon:SetTexture(FALLBACK_ICON)

        o.specText = Style.CreateText(o, "title", "text")
        o.specText:SetPoint("TOPLEFT", o.icon, "TOPRIGHT", ICON_GAP, -2)
        o.specText:SetWidth(TEXT_W)
        o.specText:SetJustifyH("LEFT")
        o.specText:SetWordWrap(false)

        o.loadoutText = Style.CreateText(o, "body", "text")
        o.loadoutText:SetPoint("TOPLEFT", o.specText, "BOTTOMLEFT", 0, -4)
        o.loadoutText:SetWidth(TEXT_W)
        o.loadoutText:SetJustifyH("LEFT")
        o.loadoutText:SetWordWrap(false)   -- fixed width + no wrap: the engine truncates with "..."

        -- Full spec and loadout name on hover (the line truncates at TEXT_W)
        o.loadoutHover = CreateHoverZone(o, function()
                local name = o._loadoutFull
                if not name or name == UNKNOWN_LOADOUT then name = "Unknown loadout" end
                return "Talent loadout", tostring(o._specName or UNKNOWN_SPEC) .. "\n" .. name
        end)
        o.loadoutHover:SetPoint("TOPLEFT", o.specText, "TOPLEFT", 0, 2)
        o.loadoutHover:SetPoint("BOTTOMRIGHT", o.loadoutText, "BOTTOMRIGHT", 0, -2)

        -- Durability column (right)
        o.durLabel = Style.CreateText(o, "small", "textDim")
        o.durLabel:SetPoint("TOPRIGHT", o, "TOPRIGHT", -DUR_RIGHT, -PAD)
        o.durLabel:SetText("Durability")

        o.durIcon = o:CreateTexture(nil, "ARTWORK")
        o.durIcon:SetSize(DUR_ICON, DUR_ICON)
        o.durIcon:SetPoint("RIGHT", o.durLabel, "LEFT", -3, 0)
        o.durIcon:SetAtlas(REPAIR_ATLAS)

        o.durText = Style.CreateText(o, "title", "text")
        o.durText:SetPoint("TOPRIGHT", o.durLabel, "BOTTOMRIGHT", 0, -2)

        o.lowText = Style.CreateText(o, "small", "fail")
        o.lowText:SetPoint("BOTTOMRIGHT", o.durText, "BOTTOMLEFT", -6, 1)

        o.durBar = Style.CreateBar(o, { width = DUR_COL_W, height = DUR_BAR_H })
        o.durBar:SetMinMaxValues(0, 100)
        o.durBar:SetPoint("TOPRIGHT", o.durText, "BOTTOMRIGHT", 0, -4)

        o.durHover = CreateHoverZone(o, function() return "Durability", DurabilityTipText() end)
        o.durHover:SetPoint("TOPRIGHT", o, "TOPRIGHT", -DUR_RIGHT, -(PAD - 2))
        o.durHover:SetPoint("BOTTOMLEFT", o.durBar, "BOTTOMLEFT", 0, -2)

        -- Collapsed single-line summary
        o.collapsedText = Style.CreateText(o, "body", "text")
        o.collapsedText:SetPoint("LEFT", o, "LEFT", CONTENT_L, 0)
        o.collapsedText:SetWidth(PANEL_W - CONTENT_L - DUR_RIGHT)
        o.collapsedText:SetJustifyH("LEFT")
        o.collapsedText:SetWordWrap(false)
        o.collapsedText:Hide()
end

-- REPAIR NEEDED banner and the override hint row
local function BuildOverlayBanner(o)
        -- REPAIR NEEDED banner row: solid fail-coloured fill, title font, pulsing repair icon
        local fr, fg, fb = Style.Color("fail")
        o.banner = CreateFrame("Frame", nil, o)
        o.banner:SetPoint("TOPLEFT", o, "TOPLEFT", ACCENT_W, -HEADER_H)
        o.banner:SetPoint("TOPRIGHT", o, "TOPRIGHT", -1, -HEADER_H)
        o.banner:SetHeight(BANNER_H)
        o.banner.fill = o.banner:CreateTexture(nil, "BACKGROUND")
        o.banner.fill:SetAllPoints(o.banner)
        o.banner.fill:SetColorTexture(fr, fg, fb, 0.42)
        o.banner.lineTop = o.banner:CreateTexture(nil, "BORDER")
        o.banner.lineTop:SetPoint("TOPLEFT")
        o.banner.lineTop:SetPoint("TOPRIGHT")
        o.banner.lineTop:SetHeight(1)
        o.banner.lineTop:SetColorTexture(fr, fg, fb, 0.9)
        o.banner.lineBottom = o.banner:CreateTexture(nil, "BORDER")
        o.banner.lineBottom:SetPoint("BOTTOMLEFT")
        o.banner.lineBottom:SetPoint("BOTTOMRIGHT")
        o.banner.lineBottom:SetHeight(1)
        o.banner.lineBottom:SetColorTexture(fr, fg, fb, 0.9)
        o.banner.text = Style.CreateText(o.banner, "title", "text")
        -- icon + text centred as one group
        o.banner.text:SetPoint("CENTER", o.banner, "CENTER", (BANNER_ICON + 6) / 2, 0)
        o.banner.text:SetText("REPAIR NEEDED")
        o.banner.icon = o.banner:CreateTexture(nil, "ARTWORK")
        o.banner.icon:SetSize(BANNER_ICON, BANNER_ICON)
        o.banner.icon:SetPoint("RIGHT", o.banner.text, "LEFT", -6, 0)
        o.banner.icon:SetAtlas(REPAIR_ATLAS)
        o.banner:Hide()

        -- Override hint row under the banner: always shown in the repair state
        -- (never a hover fade), text follows the override state (UpdateHint).
        o.helper = Style.CreateText(o, "body", "wait")
        o.helper:SetPoint("TOP", o.banner, "BOTTOM", 0, -3)
        o.helper:SetWidth(PANEL_W - 2 * CONTENT_L)
        o.helper:SetJustifyH("CENTER")
        o.helper:SetWordWrap(false)
        o.helper:SetText(HELPER_HOLD)
        o.helper:Hide()
end

-- Change Talents / Ready / Not Ready / collapse buttons
local function BuildOverlayButtons(o)
        -- Button row
        o.changeBtn = Style.CreateButton(o, "Change Talents", { width = CHANGE_W, height = BUTTON_H, variant = "default" })
        StaticTip(o.changeBtn, "Change Talents", "Open the talent window to switch loadout before answering.")
        o.changeBtn:SetPoint("BOTTOMLEFT", o, "BOTTOMLEFT", CONTENT_L, PAD)
        o.changeBtn:SetScript("OnClick", function()
                if PlayerSpellsUtil and PlayerSpellsUtil.TogglePlayerSpellsFrame then
                        local tab = (PlayerSpellsUtil.FrameTabs and PlayerSpellsUtil.FrameTabs.ClassTalents) or 2
                        pcall(PlayerSpellsUtil.TogglePlayerSpellsFrame, tab)
                end
        end)

        o.readyBtn = Style.CreateButton(o, "Ready", { width = BTN_W, height = BUTTON_H, variant = "success" })
        o.readyBtn:SetPoint("BOTTOMRIGHT", o, "BOTTOMRIGHT", -PAD, PAD)

        o.notReadyBtn = Style.CreateButton(o, "Not Ready", { width = BTN_W, height = BUTTON_H, variant = "danger" })
        o.notReadyBtn:SetPoint("RIGHT", o.readyBtn, "LEFT", -PAD, 0)
        StaticTip(o.notReadyBtn, "Not Ready", "Answer the ready check: not ready. In a test, nothing is sent.")

        o.collapseBtn = Style.CreateButton(o, "\226\128\147", { width = COLLAPSE_SIZE, height = COLLAPSE_SIZE, variant = "ghost" })
        o.collapseBtn:SetPoint("TOPRIGHT", o, "TOPRIGHT", -4, -4)
        DynamicTip(o.collapseBtn, function()
                if o.collapsed then return "Expand", "Show the details and the Ready / Not Ready buttons." end
                return "Collapse", "Shrink to one line. The next ready check opens expanded."
        end)

        -- Style.CreateButton makes unnamed buttons; keep the historical global names
        -- resolvable (e.g. /click RCPTOverlayReady).
        _G[addonName .. "ChangeTalentsOverlay"] = o.changeBtn
        _G[addonName .. "OverlayReady"] = o.readyBtn
        _G[addonName .. "OverlayNotReady"] = o.notReadyBtn
        _G[addonName .. "OverlayCollapse"] = o.collapseBtn

        o.expandedRegions = {
                o.iconBorder, o.icon, o.specText, o.loadoutText, o.loadoutHover,
                o.durLabel, o.durIcon, o.durText, o.lowText, o.durBar, o.durHover,
                o.changeBtn, o.readyBtn, o.notReadyBtn,
        }
end

-- Ready gate visuals, tooltip and the Ctrl-hold hitbox; returns btn, hitbox, ReadyTip
local function BuildOverlayReadyGate(o)
        -- Ready: hold-progress fill (over btn.fill, under the label) and glow
        local btn = o.readyBtn
        local rr, rg, rb = Style.Color("ready")
        btn.progress = btn:CreateTexture(nil, "BACKGROUND", nil, -6)
        btn.progress:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
        btn.progress:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 1, 1)
        btn.progress:SetColorTexture(rr, rg, rb, 0.45)
        btn.progress:Hide()
        function btn:SetProgress(frac)
                local w = (self:GetWidth() - 2) * (frac or 0)
                if w < 1 then
                        self.progress:Hide()
                else
                        self.progress:SetWidth(w)
                        self.progress:Show()
                end
        end

        btn.glow = btn:CreateTexture(nil, "ARTWORK", nil, 1)
        btn.glow:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
        btn.glow:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        btn.glow:SetColorTexture(rr, rg, rb, 0.25)
        btn.glow:SetBlendMode("ADD")
        btn.glow:Hide()

        -- Hold tracking state
        btn._hold = { elapsed = 0, required = HOLD_SECONDS, tracking = false, mouseOver = false }

        -- Lightweight OnUpdate tracker frame; shown only while tracking
        o._holdFrame = CreateFrame("Frame")
        o._holdFrame:SetScript("OnUpdate", function(_, elapsed)
                local hb = btn._hold
                if not hb.tracking then return end
                hb.elapsed = hb.elapsed + elapsed
                local frac = hb.elapsed / hb.required
                if frac > 1 then frac = 1 end
                btn:SetProgress(frac)
                if frac >= 1 then
                        pcall(o.CompleteOverride, o)
                end
        end)
        o._holdFrame:Hide()

        -- Invisible top-level hitbox over the Ready button: receives the mouse
        -- while Ready is disabled so the Ctrl-hold override can start.
        -- Ready tooltip: explains the durability gate while Ready is blocked.
        local function ReadyTip()
                if o._repair then
                        if o._overrideReady then
                                return "Ready (override)", "Override armed: click to answer Ready despite low durability."
                        end
                        return "Ready is blocked", string.format(
                                "%d slot(s) below %d%% durability. Repair, or hold Ctrl over this button for %.1fs to ready anyway.",
                                o._lowSlots or 0, Threshold(), HOLD_SECONDS)
                end
                if o.simulated then return "Ready", "Test: shows the mini bar; nothing is sent." end
                return "Ready", "Answer the ready check: ready."
        end
        o.ReadyTip = ReadyTip
        DynamicTip(btn, ReadyTip)

        -- Invisible top-level hitbox over the Ready button: receives the mouse
        -- while Ready is disabled so the Ctrl-hold override can start. SetAllPoints
        -- resolves in screen space, so it tracks the button at any overlay scale;
        -- ApplyScale keeps its own scale equal to the overlay's as well.
        local hitbox = CreateFrame("Button", addonName .. "OverlayReadyHitbox", UIParent)
        btn.hitbox = hitbox
        hitbox:SetAllPoints(btn)
        hitbox:SetScale(FrameScale())
        hitbox:EnableMouse(true)
        hitbox:SetHitRectInsets(0, 0, 0, 0)
        pcall(function()
                hitbox:SetFrameStrata("DIALOG")
                hitbox:SetFrameLevel((o:GetFrameLevel() or 0) + 200)
        end)
        hitbox:Hide()

        hitbox:SetScript("OnEnter", function(self)
                btn._hold.mouseOver = true
                ShowDynamicTip(self, ReadyTip)
                if not btn:IsEnabled() and IsControlKeyDown() then
                        pcall(o.StartOverride, o)
                end
        end)

        hitbox:SetScript("OnLeave", function(self)
                btn._hold.mouseOver = false
                HideTip(self)
                if btn._hold.tracking then
                        pcall(o.CancelOverride, o)
                end
        end)

        -- Modifier tracking, centralised here to avoid conflicting OnEnter/OnLeave
        -- events causing flicker. The hint row is driven by UpdateHint only.
        hitbox:SetScript("OnUpdate", function(self)
                local hb = btn._hold
                local inside = CursorIsOverFrame(self)
                hb.mouseOver = inside
                if inside then
                        if IsControlKeyDown() then
                                if not hb.tracking and not btn:IsEnabled() and not o._overrideLocked then
                                        o:StartOverride()
                                end
                        else
                                if hb.tracking then o:CancelOverride() end
                                -- clear lock when modifier released
                                if o._overrideLocked then o._overrideLocked = false; o._suspendPeriodic = nil end
                        end
                else
                        if hb.tracking then o:CancelOverride() end
                        if not IsControlKeyDown() and o._overrideLocked then o._overrideLocked = false end
                end
        end)

        -- Forward clicks on the hitbox to the real ready button while override is active
        hitbox:SetScript("OnMouseUp", function(_, button)
                if button ~= "LeftButton" then return end
                if not (o._overrideReady or o._overrideLocked) then return end
                pcall(Debug, string.format("RCPT: Hitbox forwarding click to overlay.readyBtn; _overrideReady=%s, _overrideLocked=%s", tostring(o._overrideReady), tostring(o._overrideLocked)))
                if btn:IsEnabled() then pcall(btn.Click, btn) end
        end)
        return btn, hitbox, ReadyTip
end

-- Override start / cancel / complete, answering and button clicks
local function AttachOverlayOverride(o, btn, hitbox, ReadyTip)
        ----------------------------------------------------------------
        -- Override: start / cancel / complete
        ----------------------------------------------------------------

        -- Hint row: visible whenever the repair gate is on screen; text follows
        -- the override (idle / holding / armed). Plain Show/Hide, no fades.
        function o:UpdateHint()
                local show = (self._repair and not self.collapsed) and true or false
                if show then
                        local text = HELPER_HOLD
                        if self._overrideReady then
                                text = HELPER_ARMED
                        elseif btn._hold.tracking then
                                text = HELPER_HOLDING
                        end
                        self.helper:SetText(text)
                end
                self.helper:SetShown(show)
        end

        function o:StartOverride()
                if self._overrideLocked then return end
                local hb = btn._hold
                if hb.tracking then return end
                hb.tracking = true
                hb.elapsed = 0
                btn:SetProgress(0)
                btn.glow:Show()
                Style.Pulse(btn.glow)
                self:UpdateHint()
                self._holdFrame:Show()
        end

        function o:CancelOverride()
                local hb = btn._hold
                hb.tracking = false
                hb.elapsed = 0
                btn:SetProgress(0)
                Style.StopPulse(btn.glow)
                btn.glow:Hide()
                self:UpdateHint()
                self._holdFrame:Hide()
        end

        function o:CompleteOverride()
                local hb = btn._hold
                hb.tracking = false
                hb.elapsed = hb.required
                btn:SetProgress(1)
                Style.StopPulse(btn.glow)
                btn.glow:Hide()
                self._holdFrame:Hide()

                -- grant a single ready press
                self._overrideReady = true
                -- lock starting new overrides until the modifier is released
                self._overrideLocked = true
                -- temporary freeze to avoid periodic checks re-disabling immediately
                self._freezeUntil = GetTime() + OVERRIDE_FREEZE
                -- suspend the periodic overlay updater while the override is being consumed
                self._suspendPeriodic = true
                btn:Enable()
                self:UpdateHint()
                if GameTooltip and GameTooltip:IsOwned(hitbox) then ShowDynamicTip(hitbox, ReadyTip) end

                -- if unused after timeout, revoke
                C_Timer.After(OVERRIDE_REVOKE, function()
                        if overlay and overlay._overrideReady then
                                overlay._overrideReady = false
                                overlay.readyBtn:Disable()
                                pcall(overlay.CancelOverride, overlay)
                        end
                end)
        end

        ----------------------------------------------------------------
        -- Answering
        ----------------------------------------------------------------

        function o:Respond(ready)
                if self.simulated then
                        -- test mode: never touch the real ready check
                        ShowMini(ready and "ready" or "notready")
                        self:StartTimer(SIM_MINI_SECONDS, function()
                                if overlay then overlay:EndSession(true) end
                        end)
                        return
                end
                ClickDefault(ready)
        end

        -- Click behavior: allow exactly one click when override is granted
        btn:SetScript("OnClick", function(self)
                pcall(Debug, string.format("RCPT: overlay.readyBtn clicked; _overrideReady=%s, _overrideLocked=%s", tostring(o._overrideReady), tostring(o._overrideLocked)))
                if o._overrideReady then
                        o._overrideReady = false
                        o:Respond(true)
                        -- immediately re-disable the overlay ready button and clear visuals
                        self:Disable()
                        o:CancelOverride()
                        return
                end
                o:Respond(true)
        end)

        o.notReadyBtn:SetScript("OnClick", function()
                o:Respond(false)
        end)

        o.collapseBtn:SetScript("OnClick", function()
                o.collapsed = not o.collapsed
                o:Layout()
        end)
end

-- Hitbox sync, layout, refresh and placement
local function AttachOverlayLayout(o, btn, hitbox)
        ----------------------------------------------------------------
        -- Layout and refresh
        ----------------------------------------------------------------

        -- Hitbox only while the Ready gate is in force and the button is on screen.
        function o:SyncHitbox()
                if self:IsShown() and not self.collapsed and self._repair then
                        hitbox:Show()
                else
                        hitbox:Hide()
                end
        end

        -- Expanded height, whether or not the overlay is collapsed right now.
        function o:FullHeight()
                return EXPANDED_H + (self._repair and REPAIR_EXTRA or 0)
        end

        -- The overlay is TOP-anchored: collapse/expand and the repair rows change
        -- the height downwards only, so the collapse button stays put.
        function o:Layout()
                local collapsed = self.collapsed
                local repair = self._repair and not collapsed
                for _, region in ipairs(self.expandedRegions) do
                        region:SetShown(not collapsed)
                end
                self.collapsedText:SetShown(collapsed)
                self.banner:SetShown(repair)
                if repair then Style.Pulse(self.banner.icon) else Style.StopPulse(self.banner.icon) end
                if collapsed then self:CancelOverride() end
                self:UpdateHint()
                self:SetHeight(collapsed and COLLAPSED_H or self:FullHeight())
                self.collapseBtn:SetText(collapsed and "+" or "\226\128\147")
                -- above Blizzard's popup the anchor depends on the repair rows (bottom stays 20px clear)
                if not UseReplace() and ReadyCheckFrame then self:Place() end
                self:SyncHitbox()
        end

        function o:Refresh()
                local threshold = Threshold()
                local isLow, numLowSlots, avgDur = CheckLowDurability(threshold)
                local specName, loadoutName, icon = GetSpecAndLoadout()
                local pct = floor((avgDur or 100) + 0.5)
                local durState = DurabilityState(avgDur or 100, isLow, threshold)

                self._lowSlots = numLowSlots or 0
                self._specName = specName
                self._loadoutFull = loadoutName
                self.icon:SetTexture(icon or FALLBACK_ICON)
                self.specText:SetText(specName or UNKNOWN_SPEC)
                self.loadoutText:SetText(FormatLoadout(loadoutName))
                self.durText:SetText(string.format("%d%%", pct))
                self.durText:SetTextColor(Style.Color(durState))
                self.lowText:SetText((numLowSlots or 0) > 0 and string.format("%d low", numLowSlots) or "")
                self.durBar:SetValue(math.max(0, math.min(100, avgDur or 100)))
                self.durBar:SetBarColor(durState)
                self.collapsedText:SetText(table.concat({
                        specName or UNKNOWN_SPEC,
                        Style.Colorize("textDim", DOT),
                        (loadoutName ~= UNKNOWN_LOADOUT and loadoutName) or Style.Colorize("textDim", "Unknown loadout"),
                        Style.Colorize("textDim", DOT),
                        Style.Colorize(durState, string.format("%d%%", pct)),
                }))

                -- Ready gate: disabled while any slot is below the threshold
                if isLow then
                        local now = GetTime()
                        if not self._freezeUntil or now >= self._freezeUntil then
                                btn:Disable()
                        end
                else
                        -- cancel any in-progress hold when durability recovers
                        self._overrideReady = false
                        self:CancelOverride()
                        btn:Enable()
                end

                if self._repair ~= isLow then
                        self._repair = isLow
                        self:Layout()
                else
                        self:SyncHitbox()
                end

                local status = (not self.simulated) and PlayerReadyStatus() or nil
                if isLow then
                        self:SetAccent("fail")
                elseif status == "ready" then
                        self:SetAccent("ready")
                elseif status == "notready" then
                        self:SetAccent("fail")
                else
                        self:SetAccent("accent")
                end
        end

        function o:Place()
                self:ClearAllPoints()
                if not UseReplace() and ReadyCheckFrame then
                        -- keep Blizzard's popup and sit directly above it: bottom edge 20px
                        -- above its top (clears the border art, ~16px above the frame).
                        -- Anchored by TOP at the expanded height, so collapsing keeps the top.
                        self:SetPoint("TOP", ReadyCheckFrame, "TOP", 0, 20 + self:FullHeight())
                elseif not ApplySavedKey(self, "overlayPos") then
                        -- default: where the centred overlay always sat, TOP-anchored
                        self:SetPoint("TOP", UIParent, "CENTER", 0, EXPANDED_H / 2)
                end
        end
end

-- Session lifecycle, event watcher and frame scripts
local function AttachOverlaySession(o, btn, hitbox)
        ----------------------------------------------------------------
        -- Session lifecycle
        ----------------------------------------------------------------

        function o:StartTimer(seconds, fn)
                self:StopTimer()
                self._autoHideTimer = C_Timer.NewTimer(seconds, fn)
        end

        function o:StopTimer()
                if self._autoHideTimer then
                        pcall(self._autoHideTimer.Cancel, self._autoHideTimer)
                        self._autoHideTimer = nil
                end
        end

        -- Failure-safe: the overlay is populated and shown first; Blizzard's popup is
        -- hidden only once the overlay is up. Any error clears the session and leaves
        -- (or puts back) Blizzard's popup, then re-raises for the caller's Debug.
        function o:BeginSession(simulated, isInitiator)
                RegisterOverlays()
                self.sessionActive = true
                self.simulated = simulated and true or nil
                -- every ready check opens expanded, so Ready / Not Ready are on screen
                self.collapsed = false
                -- a mini bar right-clicked away stays away for one ready check only
                if mini then mini.dismissed = nil end
                local hidDefault = false

                local ok, err = pcall(function()
                        ApplyScale()
                        self:Place()
                        self:CancelOverride()
                        if mini and mini:IsShown() then mini:Hide() end
                        self:Layout()
                        self:Refresh()
                        Style.FadeIn(self, FADE_IN)
                        if not self:IsShown() then error("ready check overlay did not show") end
                        if UseReplace() then
                                hidDefault = ReadyCheckFrame ~= nil and ReadyCheckFrame:IsShown()
                                HideDefaultFrame()
                        end
                        self:SyncHitbox()

                        if self.simulated then
                                self.watcher:UnregisterAllEvents()
                        else
                                self.watcher:RegisterEvent("READY_CHECK_FINISHED")
                                self.watcher:RegisterEvent("READY_CHECK_CONFIRM")
                        end

                        -- Auto-hide: simulated sessions always; real ones only once the
                        -- player has answered (the overlay may be the only answer UI).
                        -- READY_CHECK_FINISHED and teardown still end a real session.
                        self:StartTimer(AUTO_HIDE_SECONDS, function()
                                if not overlay then return end
                                if overlay.simulated then
                                        overlay:EndSession(true)
                                elseif overlay:IsShown() then
                                        -- only a known answer: nil (unreadable) may leave the overlay as the only answer UI
                                        local s = PlayerReadyStatus()
                                        if s == "ready" or s == "notready" then overlay:EndSession(true) end
                                end
                        end)

                        -- Already answered (or initiated): go straight to the mini bar
                        local status = (not self.simulated) and PlayerReadyStatus() or nil
                        if status == "ready" or status == "notready" then
                                ShowMini(status)
                        elseif isInitiator then
                                ShowMini("ready")
                        end
                end)
                if ok then return end

                local wasSimulated = self.simulated
                self.sessionActive = false
                pcall(function()
                        if self:IsShown() then self:Hide() else self:Cleanup(false) end
                end)
                if hidDefault and not wasSimulated then RestoreDefaultFrame() end
                error(err, 0)
        end

        -- End the session; `fade` for cosmetic exits (finished, auto-hide).
        function o:EndSession(fade)
                self.sessionActive = false
                if self:IsShown() then
                        if fade then Style.FadeOut(self, FADE_OUT) else self:Hide() end
                else
                        self:Cleanup(fade)
                end
        end

        function o:Cleanup(fadeMini)
                self.sessionActive = false
                self.simulated = nil
                btn._hold.mouseOver = false
                self.helper:Hide()
                self:CancelOverride()
                self:StopTimer()
                self.watcher:UnregisterAllEvents()
                if mini and mini:IsShown() then
                        if fadeMini then Style.FadeOut(mini, FADE_OUT) else mini:Hide() end
                end
                -- clear any temporary freeze/lock state so future ready checks behave normally
                self._freezeUntil = nil
                self._overrideLocked = false
                self._overrideReady = false
                self._suspendPeriodic = nil
                hitbox:Hide()
        end

        o.watcher = CreateFrame("Frame")
        o.watcher:SetScript("OnEvent", function(_, event, ...)
                if event == "READY_CHECK_FINISHED" then
                        o:EndSession(true)
                elseif event == "READY_CHECK_CONFIRM" then
                        if not o.sessionActive or o.simulated then return end
                        local unitTarget, isReady = ...
                        if IsPlayer(unitTarget) then
                                local state
                                if not IsSecret(isReady) and isReady ~= nil then
                                        state = isReady and "ready" or "notready"
                                end
                                ShowMini(state or PlayerReadyStatus() or "waiting")
                        end
                end
        end)

        o:SetScript("OnShow", function(self)
                self:SyncHitbox()
                -- Hiding stops animations, and Refresh may start the pulse before the
                -- overlay is shown: (re)start the REPAIR NEEDED icon pulse here.
                if self._repair and not self.collapsed then Style.Pulse(self.banner.icon) end
        end)

        o:SetScript("OnHide", function(self)
                hitbox:Hide()
                if self._suppressOnHideClear and self.sessionActive then
                        -- intentional hide of the primary overlay: keep watcher/timers and the mini bar
                        self._suppressOnHideClear = nil
                        btn._hold.mouseOver = false
                        self.helper:Hide()
                        self:CancelOverride()
                        return
                end
                self:Cleanup(false)
        end)

        -- Periodic refresh while the main overlay is shown
        o:SetScript("OnUpdate", function(self, elapsed)
                -- if periodic checks are suspended for this ready check, skip
                if self._suspendPeriodic then return end
                self.updateTicker = self.updateTicker + elapsed
                if self.updateTicker < REFRESH_SECONDS then return end
                self.updateTicker = 0
                local ok, err = pcall(self.Refresh, self)
                if not ok then Debug("RCPT: overlay refresh error: " .. tostring(err)) end
        end)
end

local function CreateReadyOverlay()
        if overlay then return overlay end
        RefreshAddon()
        if not Style then
                Debug("RCPT: Style unavailable; ready check overlay disabled")
                return nil
        end

        -- DIALOG, like Blizzard's ReadyCheckFrame: never behind the options panel (HIGH)
        local o = Style.CreatePanel(addonName .. "ReadyOverlay", UIParent, {
                width = PANEL_W, height = EXPANDED_H, strata = "DIALOG", accent = "left",
        })
        overlay = o
        o:SetScale(FrameScale())
        -- TOP-anchored so collapsing keeps the collapse button under the cursor
        o:SetPoint("TOP", UIParent, "CENTER", 0, EXPANDED_H / 2)
        o.collapsed = false
        o.updateTicker = 0
        o._overrideReady = false
        o._overrideLocked = false

        BuildOverlayHeader(o)
        BuildOverlayBanner(o)
        BuildOverlayButtons(o)
        local btn, hitbox, ReadyTip = BuildOverlayReadyGate(o)
        AttachOverlayOverride(o, btn, hitbox, ReadyTip)
        AttachOverlayLayout(o, btn, hitbox)
        AttachOverlaySession(o, btn, hitbox)

        if ReadyCheckFrame then
                ReadyCheckFrame:HookScript("OnShow", OnDefaultShown)
                ReadyCheckFrame:HookScript("OnHide", OnDefaultHidden)
        end

        -- Drag to move (saved in RCPT_TalentCheckDB.overlayPos) only while the
        -- overlay replaces Blizzard's popup. Set up after o:SetScript("OnHide"),
        -- which would otherwise drop MakeDraggable's OnHide hook.
        MakeDraggable(o, CanDrag, function(self) SavePosition(self, "overlayPos") end)

        -- Single source of truth for "is this overlay active and in use?"
        o.IsActiveOverlay = function(self) return self:IsShown() end

        o:Layout()
        o:Hide()
        RegisterOverlays()
        return o
end

------------------------------------------------------------------------
-- Merchant: refresh as soon as the player closes a vendor (repair)
------------------------------------------------------------------------

local merchantFrame = CreateFrame("Frame")

local function StopMerchantWatch()
        merchantFrame:UnregisterEvent("MERCHANT_CLOSED")
end

merchantFrame:SetScript("OnEvent", function()
        if overlay and overlay:IsShown() and not overlay._suspendPeriodic then pcall(overlay.Refresh, overlay) end
        if mini and mini:IsShown() then pcall(PopulateMini, mini) end
        if not CheckLowDurability(Threshold()) then StopMerchantWatch() end
end)

local function StartMerchantWatch()
        merchantFrame:RegisterEvent("MERCHANT_CLOSED")
end

------------------------------------------------------------------------
-- Ready check entry point
------------------------------------------------------------------------

local function SendReport(isLow, numLowSlots, avgDur)
        local db = DB()
        -- Determine which report mode applies for the current group type
        local reportMode = "NONE"
        if IsInRaid and IsInRaid() then
                reportMode = db.RaidReportMode or "NONE"
        elseif IsInGroup and IsInGroup() then
                reportMode = db.PartyReportMode or "NONE"
        end
        if not reportMode or reportMode == "NONE" then return end

        pcall(function()
                if Addon and Addon.EncounterRestrictionsActive and Addon.EncounterRestrictionsActive() then
                        Debug("Skipping SendChatMessage due to encounter restrictions")
                        return
                end
                local loadoutName = GetCurrentLoadoutName()
                if reportMode == "EMOTE" then
                        SendChat("almost forgot to set their talents to " .. (loadoutName or UNKNOWN_LOADOUT), "EMOTE")
                elseif reportMode == "WHISPER" then
                        local playerName = UnitName("player")
                        if not IsSecret(playerName) and playerName then
                                SendChat("I am currently using talents: " .. (loadoutName or UNKNOWN_LOADOUT), "WHISPER", nil, playerName)
                                if isLow then
                                        SendChat(string.format("Current Durability: %d%%, Low Slots: %d", floor((avgDur or 100) + 0.5), numLowSlots or 0), "WHISPER", nil, playerName)
                                end
                        end
                else
                        -- SAY and YELL require a hardware event outside of instances; skip if not instanced
                        if (reportMode == "SAY" or reportMode == "YELL") and not IsInInstance() then
                                Debug("RCPT: Skipping " .. reportMode .. " outside instance (requires hardware event)")
                        else
                                SendChat("I am currently using talents: " .. (loadoutName or UNKNOWN_LOADOUT), reportMode)
                                if isLow then
                                        SendChat(string.format("Current Durability: %d%%, Low Slots: %d", floor((avgDur or 100) + 0.5), numLowSlots or 0), reportMode)
                                end
                        end
                end
        end)
end

-- `initiator` is the READY_CHECK payload (may be a secret value; only
-- IsPlayer touches it). `simulated` = test mode: no chat, no real answers.
local function RunReadyCheck(initiator, simulated)
        if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        RefreshAddon()
        local isLow, numLowSlots, avgDur = CheckLowDurability(Threshold())

        if not simulated then SendReport(isLow, numLowSlots, avgDur) end

        local o = CreateReadyOverlay()
        if o then
                local isInitiator = false
                if not simulated then
                        local okI, res = pcall(IsPlayer, initiator)
                        isInitiator = okI and res == true
                end
                local ok, err = pcall(o.BeginSession, o, simulated, isInitiator)
                if not ok then Debug("RCPT: overlay error: " .. tostring(err)) end
        end

        if isLow then StartMerchantWatch() else StopMerchantWatch() end
end

local function TalentEventHandler(_, event, ...)
        if event == "PLAYER_LOGIN" then
                if Addon and Addon.EnsureDefaults then
                        pcall(function() Addon:EnsureDefaults() end)
                else
                        if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
                end
        elseif event == "READY_CHECK" then
                local initiator = ...
                -- must never raise: a broken handler would leave the check unhandled
                local ok, err = pcall(RunReadyCheck, initiator, false)
                if not ok then Debug("RCPT: ready check handler error: " .. tostring(err)) end
        elseif event == "PLAYER_REGEN_DISABLED" then
                -- the mini bar must not catch world clicks or camera turning in combat
                if mini then mini:EnableMouse(false) end
        elseif event == "PLAYER_REGEN_ENABLED" then
                if mini then mini:EnableMouse(true) end
        end
end

------------------------------------------------------------------------
-- Exports, init and teardown (assigned at load, before registration)
------------------------------------------------------------------------

-- Returns false (and prints why) while a real ready check is on: simulating
-- would take over its session and leave it unanswerable.
local function SimulateReadyCheckEvent()
        if overlay and overlay.sessionActive and not overlay.simulated then
                RefreshAddon()
                local msg = "A ready check is in progress; the test was skipped."
                if Addon and Addon.Print then Addon.Print(msg) else print("[RCPT] " .. msg) end
                return false
        end
        RunReadyCheck(nil, true)
        return true
end

local function ShowReadyCheckDebug()
        if not SimulateReadyCheckEvent() then return end
        pcall(function()
                if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then
                        PlaySound(SOUNDKIT.READY_CHECK)
                end
        end)
end

local function HideOverlay()
        if overlay then overlay:EndSession(false) end
end

local function ensureExports()
        Exports.CheckLowDurability = CheckLowDurability
        Exports.GetCurrentLoadoutName = GetCurrentLoadoutName
        Exports.GetSpecAndLoadout = GetSpecAndLoadout
        Exports.TriggerReadyCheck = function(initiator) RunReadyCheck(initiator, false) end
        Exports.SimulateReadyCheckEvent = SimulateReadyCheckEvent
        Exports.ShowReadyCheckDebug = ShowReadyCheckDebug
        Exports.HideOverlay = HideOverlay
        Exports.ResetPositions = ResetPositions
        _G.RCPT_TalentCheck = Exports
end

-- Keyed listener (re-init never duplicates); the table may not exist yet.
local function RegisterFrameSettingListener()
        local core = _G.RCPT or Addon
        if type(core) ~= "table" then return end
        if type(core.frameSettingListeners) ~= "table" then core.frameSettingListeners = {} end
        core.frameSettingListeners.talent = OnFrameSettingsChanged
end

local function InitTalentModule()
        RefreshAddon()
        RegisterFrameSettingListener()
        frame:SetScript("OnEvent", TalentEventHandler)
        frame:RegisterEvent("PLAYER_LOGIN")
        frame:RegisterEvent("READY_CHECK")
        frame:RegisterEvent("PLAYER_REGEN_DISABLED")
        frame:RegisterEvent("PLAYER_REGEN_ENABLED")
        ensureExports()
        RegisterOverlays()
        _G.RCPT_TalentActive = true
end

local function TalentTeardown()
        pcall(HideOverlay)
        StopMerchantWatch()
        -- Unregister overlay frames from the shared registry
        local core = _G.RCPT
        if core and core.UnregisterOverlayFrame then
                pcall(core.UnregisterOverlayFrame, core, "TalentCheckOverlay")
                pcall(core.UnregisterOverlayFrame, core, "TalentCheckMiniOverlay")
        end
        frame:UnregisterAllEvents()
        frame:SetScript("OnEvent", nil)
        -- Exports stay assigned so the options "Test ready check" button keeps working.
        _G.RCPT_TalentActive = false
        Debug("TalentCheck module torn down.")
end

ensureExports()
_G.RCPT_TalentInitialize = InitTalentModule
_G.RCPT_TalentTeardown = TalentTeardown

function Module.Init(addon)
        if addon then Addon = addon end
        InitTalentModule()
end

-- Register with core Addon registry if available, otherwise initialize immediately
if _G.RCPT and type(_G.RCPT.RegisterModule) == "function" then
        _G.RCPT:RegisterModule("TalentCheck", Module)
else
        InitTalentModule()
end
