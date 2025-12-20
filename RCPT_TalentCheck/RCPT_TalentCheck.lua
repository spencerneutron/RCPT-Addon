-- Full TalentCheck module (migrated from root `TalentCheck.lua`)

-- Documenting old WeakAura behavior:

-- Trigger: Event -> READY_CHECK
-- Condition: None
-- Action:
--  OnInit:

        -- aura_env.CheckLowDurability = function (threshold)
        --     local numLowSlots = 0
        --     local totalDurability = 0
        --     local numSlotsWithDurability = 0
        --     ...

-- Scaffolding implementation: convert documented WeakAura behavior
-- into addon-style behavior. This file registers a READY_CHECK
-- listener, checks equipment durability, adjusts the ReadyCheck UI,
-- and provides a "Change Talents" button plus optional party chat.

local addonName = "RCPT"

RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}
local db = RCPT_TalentCheckDB

local Module = {}
local Addon = _G.RCPT
local TDB = RCPT_TalentCheckDB

local function RefreshDB()
        Addon = Addon or _G.RCPT
        TDB = (Addon and Addon.talentDB) or RCPT_TalentCheckDB
end

RefreshDB()

-- Local debug wrapper that delegates to the global helper when available.
local function Debug(msg)
        if _G and _G.RCPT_Debug then
                _G.RCPT_Debug(msg)
        end
end

local function CheckLowDurability(threshold)
        threshold = threshold or (TDB and TDB.MinDurabilityPercent) or 80
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

local frame = CreateFrame("Frame", addonName .. "TalentCheckFrame")

local overlay = nil
local GetSpecAndLoadout
local function CreateReadyOverlay()
        if overlay and overlay:IsShown() then return overlay end
        if overlay then return overlay end

        overlay = CreateFrame("Frame", addonName .. "ReadyOverlay", UIParent, "BackdropTemplate")
        overlay:SetSize(360, 88)
        overlay:SetFrameStrata("HIGH")
        overlay:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = false,
                edgeSize = 8,
        })
        overlay:SetBackdropColor(0, 0, 0, 0.7)
        overlay:SetPoint("BOTTOM", ReadyCheckFrame or UIParent, "TOP", 0, 8)

        overlay.specText = overlay:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        overlay.specText:SetPoint("TOPLEFT", 12, -10)

        overlay.loadoutText = overlay:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        overlay.loadoutText:SetPoint("TOPLEFT", overlay.specText, "BOTTOMLEFT", 0, -6)

        overlay.durText = overlay:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        overlay.durText:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -36, -12)

        overlay.repairText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        overlay.repairText:SetPoint("CENTER", 0, -4)
        overlay.repairText:SetTextColor(1, 0.1, 0.1)
        overlay.repairText:Hide()

        overlay.changeBtn = CreateFrame("Button", addonName .. "ChangeTalentsOverlay", overlay, "UIPanelButtonTemplate")
        overlay.changeBtn:SetSize(120, 22)
        overlay.changeBtn:SetPoint("BOTTOMLEFT", 12, 10)
        overlay.changeBtn:SetText("Change Talents")
        overlay.changeBtn:SetScript("OnClick", function()
                if PlayerSpellsUtil and PlayerSpellsUtil.TogglePlayerSpellsFrame then
                        pcall(PlayerSpellsUtil.TogglePlayerSpellsFrame, 2)
                        return
                end
                if ToggleTalentFrame then pcall(ToggleTalentFrame) end
        end)

        overlay.readyBtn = CreateFrame("Button", addonName .. "OverlayReady", overlay, "UIPanelButtonTemplate")
        overlay.readyBtn:SetSize(80, 22)
        overlay.readyBtn:SetPoint("BOTTOMRIGHT", -12, 10)
        overlay.readyBtn:SetText("Ready")

        -- Hold-to-override state
        overlay._overrideReady = false
        overlay._overrideLocked = false

        -- Click behavior: allow exactly one click when override is granted
        overlay.readyBtn:SetScript("OnClick", function(self)
                pcall(Debug, string.format("RCPT: overlay.readyBtn clicked; _overrideReady=%s, _overrideLocked=%s", tostring(overlay and overlay._overrideReady), tostring(overlay and overlay._overrideLocked)))
                if overlay._overrideReady then
                        overlay._overrideReady = false
                        -- perform the ready action (attempt to click Blizzard's button)
                        pcall(function()
                                if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Click then
                                        ReadyCheckFrameYesButton:Click()
                                end
                        end)
                        -- immediately re-disable the overlay ready button
                        if self.Disable then pcall(self.Disable, self) end
                        -- clear visuals
                        if overlay.CancelOverride then pcall(overlay.CancelOverride, overlay) end
                        return
                end
                -- otherwise, default click behavior (no-op when disabled)
                pcall(function()
                        if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Click then
                                ReadyCheckFrameYesButton:Click()
                        end
                end)
        end)

        -- Progress StatusBar (hidden by default)
        overlay.readyBtn.progress = CreateFrame("StatusBar", nil, overlay.readyBtn)
        -- inset the progress bar slightly so rounded button corners mask its edges
        overlay.readyBtn.progress:SetPoint("TOPLEFT", overlay.readyBtn, "TOPLEFT", 2, -2)
        overlay.readyBtn.progress:SetPoint("BOTTOMRIGHT", overlay.readyBtn, "BOTTOMRIGHT", -2, 2)
        overlay.readyBtn.progress:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        overlay.readyBtn.progress:GetStatusBarTexture():SetHorizTile(false)
        overlay.readyBtn.progress:SetStatusBarColor(0.2, 0.6, 1, 0.35)
        overlay.readyBtn.progress:SetMinMaxValues(0, 1)
        overlay.readyBtn.progress:SetValue(0)
        overlay.readyBtn.progress:Hide()

        -- Glow texture + subtle pulse animation
        overlay.readyBtn.glow = overlay.readyBtn:CreateTexture(nil, "ARTWORK")
        -- align the glow to the button interior (match the inset progress bar)
        overlay.readyBtn.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        overlay.readyBtn.glow:SetBlendMode("ADD")
        overlay.readyBtn.glow:SetAlpha(0)
        overlay.readyBtn.glow:SetPoint("TOPLEFT", overlay.readyBtn, "TOPLEFT", 2, -2)
        overlay.readyBtn.glow:SetPoint("BOTTOMRIGHT", overlay.readyBtn, "BOTTOMRIGHT", -2, 2)
        local glowAG = overlay.readyBtn.glow:CreateAnimationGroup()
        local gIn = glowAG:CreateAnimation("Alpha")
        gIn:SetFromAlpha(0)
        gIn:SetToAlpha(0.5)
        gIn:SetDuration(0.8)
        gIn:SetOrder(1)
        local gOut = glowAG:CreateAnimation("Alpha")
        gOut:SetFromAlpha(0.5)
        gOut:SetToAlpha(0.12)
        gOut:SetDuration(0.8)
        gOut:SetOrder(2)
        glowAG:SetLooping("REPEAT")
        overlay.readyBtn.glowAnim = glowAG

        -- Helper text below the button (shows on hover even when disabled)
        overlay.readyBtn.helper = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        overlay.readyBtn.helper:SetPoint("TOP", overlay.readyBtn, "BOTTOM", 0, -4)
        overlay.readyBtn.helper:SetText("Hold Ctrl to override (1.5s)")
        overlay.readyBtn.helper:SetTextColor(0.92, 0.92, 0.78)
        overlay.readyBtn.helper:SetAlpha(0)
        overlay.readyBtn.helper:Hide()
        -- fade animations for the helper text
        local helperInGroup = overlay.readyBtn.helper:CreateAnimationGroup()
        local helperIn = helperInGroup:CreateAnimation("Alpha")
        helperIn:SetFromAlpha(0)
        helperIn:SetToAlpha(1)
        helperIn:SetDuration(0.15)
        helperIn:SetOrder(1)
        overlay.readyBtn.helper.fadeIn = helperInGroup

        local helperOutGroup = overlay.readyBtn.helper:CreateAnimationGroup()
        local helperOut = helperOutGroup:CreateAnimation("Alpha")
        helperOut:SetFromAlpha(1)
        helperOut:SetToAlpha(0)
        helperOut:SetDuration(0.12)
        helperOut:SetOrder(1)
        helperOutGroup:SetScript("OnFinished", function()
                if overlay and overlay.readyBtn and overlay.readyBtn.helper then
                        -- only hide the helper if the mouse is not currently over
                        -- the ready button (the hitbox updates `_hold.mouseOver`).
                        local stillOver = false
                        if overlay.readyBtn and overlay.readyBtn.hitbox then
                                local ok, res = pcall(CursorIsOverFrame, overlay.readyBtn.hitbox)
                                if ok and res then stillOver = true end
                        end
                        if not stillOver then
                                overlay.readyBtn.helper:Hide()
                                overlay.readyBtn.helper:SetAlpha(0)
                        else
                                -- ensure helper remains fully visible
                                overlay.readyBtn.helper:SetAlpha(1)
                        end
                end
        end)
        overlay.readyBtn.helper.fadeOut = helperOutGroup

        -- Robust cursor-inside-frame check (works independent of OnEnter/OnLeave)
        local function CursorIsOverFrame(f)
                if not f then return false end
                local ok, cx, cy = pcall(GetCursorPosition)
                if not ok or not cx or not cy then return false end
                local uiScale = UIParent and UIParent:GetScale() or 1
                cx = cx / uiScale
                cy = cy / uiScale
                local ok2, left, right, top, bottom = pcall(function()
                        return f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
                end)
                if not ok2 or not left or not right or not top or not bottom then return false end
                if cx >= left and cx <= right and cy >= bottom and cy <= top then
                        return true
                end
                return false
        end

        -- Hold tracking state
        overlay.readyBtn._hold = { elapsed = 0, required = 1.5, tracking = false, mouseOver = false }

        -- Lightweight OnUpdate tracker frame; shown only while tracking
        overlay._holdFrame = overlay._holdFrame or CreateFrame("Frame")
        overlay._holdFrame:SetScript("OnUpdate", function(_, elapsed)
                if not overlay or not overlay.readyBtn then return end
                local hb = overlay.readyBtn._hold
                if not hb.tracking then return end
                hb.elapsed = hb.elapsed + elapsed
                local frac = hb.elapsed / hb.required
                if frac > 1 then frac = 1 end
                overlay.readyBtn.progress:SetValue(frac)
                if frac >= 1 then
                        -- complete override
                        if overlay.CompleteOverride then pcall(overlay.CompleteOverride, overlay) end
                end
        end)
        overlay._holdFrame:Hide()

        -- Invisible hitbox that sits over the Ready button when it's disabled so
        -- we can still receive mouse/keyboard modifiers to start the override.
        -- Use a top-level Button for reliable mouse hit-testing and place it
        -- above everything in that area so it receives events even when the
        -- ready button or its children would otherwise intercept mouse input.
        overlay.readyBtn.hitbox = CreateFrame("Button", addonName .. "OverlayReadyHitbox", UIParent)
        overlay.readyBtn.hitbox:SetAllPoints(overlay.readyBtn)
        overlay.readyBtn.hitbox:EnableMouse(true)
        overlay.readyBtn.hitbox:SetHitRectInsets(0, 0, 0, 0)
        pcall(function()
                overlay.readyBtn.hitbox:SetFrameStrata("DIALOG")
                local baseLevel = overlay:GetFrameLevel() or 0
                overlay.readyBtn.hitbox:SetFrameLevel(baseLevel + 200)
        end)
        overlay.readyBtn.hitbox:Hide()

        overlay.readyBtn.hitbox:SetScript("OnEnter", function(self)
                local btn = overlay.readyBtn
                btn._hold.mouseOver = true
                -- If Ctrl already held, start override immediately. Do not
                -- manipulate helper visibility here; OnUpdate will manage it.
                if not btn:IsEnabled() and IsControlKeyDown() then
                        pcall(function() overlay:StartOverride(btn) end)
                end
        end)

        overlay.readyBtn.hitbox:SetScript("OnLeave", function(self)
                local btn = overlay.readyBtn
                btn._hold.mouseOver = false
                if btn._hold.tracking then
                        pcall(function() overlay:CancelOverride() end)
                end
        end)

        overlay.readyBtn.hitbox:SetScript("OnUpdate", function(self)
                local hb = overlay.readyBtn._hold
                local inside = CursorIsOverFrame(self)
                hb.mouseOver = inside

                -- Helper visibility management: centralize here to avoid
                -- conflicting OnEnter/OnLeave events causing flicker.
                local helper = overlay.readyBtn.helper
                if inside then
                        -- stop any fadeOut and ensure helper is visible
                        if helper then
                                pcall(function()
                                        if helper.fadeOut and helper.fadeOut.IsPlaying and helper.fadeOut:IsPlaying() then pcall(helper.fadeOut.Stop, helper.fadeOut) end
                                        if not helper:IsShown() and helper.fadeIn and helper.fadeIn.Play then helper:Show(); pcall(helper.fadeIn.Play, helper.fadeIn) end
                                        helper:SetAlpha(1)
                                end)
                        end
                        if IsControlKeyDown() then
                                -- only start if not locked
                                if not hb.tracking and not overlay.readyBtn:IsEnabled() and not overlay._overrideLocked then
                                        overlay:StartOverride(overlay.readyBtn)
                                end
                        else
                                if hb.tracking then
                                        overlay:CancelOverride()
                                end
                                -- clear lock when modifier released
                                if overlay._overrideLocked then overlay._overrideLocked = false; overlay._suspendPeriodic = nil end
                        end
                else
                        -- not inside: if helper visible and not tracking, initiate fadeOut
                        if helper and helper:IsShown() and not hb.tracking then
                                pcall(function()
                                        if helper.fadeIn and helper.fadeIn.IsPlaying and helper.fadeIn:IsPlaying() then pcall(helper.fadeIn.Stop, helper.fadeIn) end
                                        if helper.fadeOut and helper.fadeOut.Play then pcall(helper.fadeOut.Play, helper.fadeOut) end
                                end)
                        end
                        if hb.tracking then overlay:CancelOverride() end
                        if not IsControlKeyDown() and overlay._overrideLocked then overlay._overrideLocked = false end
                end
        end)

        -- Forward clicks on the hitbox to the real ready button while override is active
        overlay.readyBtn.hitbox:SetScript("OnMouseUp", function(self, button)
                if button ~= "LeftButton" then return end
                if not overlay then return end
                if not (overlay._overrideReady or overlay._overrideLocked) then return end
                pcall(Debug, string.format("RCPT: Hitbox forwarding click to overlay.readyBtn; _overrideReady=%s, _overrideLocked=%s", tostring(overlay._overrideReady), tostring(overlay._overrideLocked)))
                pcall(function()
                        if overlay.readyBtn and overlay.readyBtn.IsEnabled and overlay.readyBtn:IsEnabled() then
                                if overlay.readyBtn.Click then
                                        overlay.readyBtn:Click()
                                else
                                        local h = overlay.readyBtn:GetScript("OnClick")
                                        if h then pcall(h, overlay.readyBtn) end
                                end
                        end
                end)
        end)

        -- Start / cancel / complete helpers
        function overlay:StartOverride(btn)
                if not btn then btn = overlay.readyBtn end
                if self._overrideLocked then return end
                local hb = btn._hold
                if hb.tracking then return end
                hb.tracking = true
                hb.elapsed = 0
                btn.progress:SetValue(0)
                btn.progress:Show()
                if btn.glowAnim and btn.glowAnim.Play then pcall(btn.glowAnim.Play, btn.glowAnim) end
                if btn.helper then
                        pcall(function()
                                btn.helper:Show()
                                if btn.helper.fadeOut and btn.helper.fadeOut.IsPlaying and btn.helper.fadeOut:IsPlaying() then pcall(btn.helper.fadeOut.Stop, btn.helper.fadeOut) end
                                if btn.helper.fadeIn and btn.helper.fadeIn.Play then pcall(btn.helper.fadeIn.Play, btn.helper.fadeIn) end
                        end)
                end
                overlay._holdFrame:Show()
        end

        function overlay:CancelOverride()
                if not overlay or not overlay.readyBtn then return end
                local btn = overlay.readyBtn
                local hb = btn._hold
                hb.tracking = false
                hb.elapsed = 0
                btn.progress:Hide()
                btn.progress:SetValue(0)
                if btn.glowAnim and btn.glowAnim.Stop then pcall(btn.glowAnim.Stop, btn.glowAnim) end
                if btn.helper then
                        pcall(function()
                                if btn.helper.fadeIn and btn.helper.fadeIn.IsPlaying and btn.helper.fadeIn:IsPlaying() then pcall(btn.helper.fadeIn.Stop, btn.helper.fadeIn) end
                                if btn.helper.fadeOut and btn.helper.fadeOut.Play then pcall(btn.helper.fadeOut.Play, btn.helper.fadeOut) end
                        end)
                end
                overlay._holdFrame:Hide()
        end

        function overlay:CompleteOverride()
                if not overlay or not overlay.readyBtn then return end
                local btn = overlay.readyBtn
                local hb = btn._hold
                hb.tracking = false
                hb.elapsed = hb.required
                btn.progress:SetValue(1)
                if btn.glowAnim and btn.glowAnim.Stop then pcall(btn.glowAnim.Stop, btn.glowAnim) end
                if btn.helper then btn.helper:Hide() end
                overlay._holdFrame:Hide()

                -- grant a single ready press
                overlay._overrideReady = true
                -- lock starting new overrides until the modifier is released
                overlay._overrideLocked = true
                -- temporary freeze to avoid periodic checks re-disabling immediately
                if GetTime then overlay._freezeUntil = GetTime() + 0.6 end
                -- suspend the periodic overlay updater while the override is being consumed
                overlay._suspendPeriodic = true
                if btn.Enable then pcall(btn.Enable, btn) end

                -- if unused after timeout, revoke
                if C_Timer then
                        C_Timer.After(4, function()
                                if overlay and overlay._overrideReady then
                                        overlay._overrideReady = false
                                        if overlay.readyBtn and overlay.readyBtn.Disable then pcall(overlay.readyBtn.Disable, overlay.readyBtn) end
                                        if overlay and overlay.CancelOverride then pcall(overlay.CancelOverride, overlay) end
                                end
                        end)
                end
        end

        -- Mouse enter/leave hooks to enforce "mouse leaves button cancels"
        overlay.readyBtn:SetScript("OnEnter", function(self)
                self._hold.mouseOver = true
                -- show a hover hint when the button is disabled
                if not self:IsEnabled() and self.helper then
                        pcall(function()
                                self.helper:Show()
                                if self.helper.fadeOut and self.helper.fadeOut.IsPlaying and self.helper.fadeOut:IsPlaying() then pcall(self.helper.fadeOut.Stop, self.helper.fadeOut) end
                                if self.helper.fadeIn and self.helper.fadeIn.Play then pcall(self.helper.fadeIn.Play, self.helper.fadeIn) end
                        end)
                end
                -- begin if Ctrl is held and button is currently disabled due to durability
                if not self:IsEnabled() and IsControlKeyDown() then
                        pcall(function() overlay:StartOverride(self) end)
                end
        end)
        overlay.readyBtn:SetScript("OnLeave", function(self)
                self._hold.mouseOver = false
                if self._hold.tracking then
                        pcall(function() overlay:CancelOverride() end)
                else
                        -- just hide the hover helper
                        pcall(function()
                                if self.helper and self.helper.fadeIn and self.helper.fadeIn.IsPlaying and self.helper.fadeIn:IsPlaying() then pcall(self.helper.fadeIn.Stop, self.helper.fadeIn) end
                                if self.helper and self.helper.fadeOut and self.helper.fadeOut.Play then pcall(self.helper.fadeOut.Play, self.helper.fadeOut) end
                        end)
                end
        end)

        -- Watch for modifier changes when mouse is over
        overlay.readyBtn:SetScript("OnUpdate", function(self)
                local hb = self._hold
                if hb.mouseOver then
                        if IsControlKeyDown() then
                                if not hb.tracking and not self:IsEnabled() and not overlay._overrideLocked then
                                        overlay:StartOverride(self)
                                end
                        else
                                if hb.tracking then
                                        overlay:CancelOverride()
                                end
                                if overlay._overrideLocked then overlay._overrideLocked = false; overlay._suspendPeriodic = nil end
                        end
                end
        end)

        overlay.notReadyBtn = CreateFrame("Button", addonName .. "OverlayNotReady", overlay, "UIPanelButtonTemplate")
        overlay.notReadyBtn:SetSize(80, 22)
        overlay.notReadyBtn:SetPoint("BOTTOMRIGHT", overlay.readyBtn, "TOPRIGHT", 0, 6)
        overlay.notReadyBtn:SetText("Not Ready")
        overlay.notReadyBtn:SetScript("OnClick", function()
                pcall(function() if ReadyCheckFrameNoButton and ReadyCheckFrameNoButton.Click then ReadyCheckFrameNoButton:Click() end end)
        end)

        overlay.collapsed = false
        overlay.collapseBtn = CreateFrame("Button", addonName .. "OverlayCollapse", overlay, "UIPanelButtonTemplate")
        overlay.collapseBtn:SetSize(22, 22)
        overlay.collapseBtn:SetPoint("TOPRIGHT", -6, -6)
        overlay.collapseBtn:SetText("-")
        overlay.collapseBtn:SetScript("OnClick", function(self)
                overlay.collapsed = not overlay.collapsed
                if overlay.collapsed then
                        overlay:SetHeight(28)
                        overlay.specText:Hide()
                        overlay.loadoutText:Hide()
                        overlay.durText:Hide()
                        overlay.changeBtn:Hide()
                        overlay.readyBtn:Hide()
                        overlay.notReadyBtn:Hide()
                        overlay.repairText:Hide()
                        self:SetText("+")
                else
                        overlay:SetHeight(88)
                        overlay.specText:Show()
                        overlay.loadoutText:Show()
                        overlay.durText:Show()
                        overlay.changeBtn:Show()
                        overlay.readyBtn:Show()
                        overlay.notReadyBtn:Show()
                        self:SetText("-")
                end
        end)

        overlay.updateTicker = 0
        overlay:SetScript("OnUpdate", function(self, elapsed)
                if not self:IsShown() then return end
                -- if periodic checks are suspended for this ready check, skip
                if self._suspendPeriodic then return end
                self.updateTicker = self.updateTicker + elapsed
                if self.updateTicker >= 0.5 then
                        self.updateTicker = 0
                        local specName, loadoutName = _G.RCPT_GetSpecAndLoadout()
                        local isLow, numLowSlots, avgDur = CheckLowDurability((TDB and TDB.MinDurabilityPercent) or 80)
                        pcall(function()
                                                if not overlay.collapsed then
                                                        overlay.specText:SetText(specName)
                                                        overlay.loadoutText:SetText(loadoutName)
                                                        overlay.durText:SetText(string.format("Durability: %d%% (%d low)", math.floor(avgDur + 0.5), numLowSlots))
                                                end
                                        if isLow then
                                                overlay.repairText:Show()
                                                overlay.repairText:SetText("REPAIR NEEDED")
                                                if overlay.readyBtn and overlay.readyBtn.Disable then
                                                        local now = (GetTime and GetTime()) or 0
                                                        if not overlay._freezeUntil or now >= overlay._freezeUntil then
                                                                overlay.readyBtn:Disable()
                                                                if overlay.readyBtn.hitbox then pcall(function() overlay.readyBtn.hitbox:Show() end) end
                                                        end
                                                end
                                        else
                                                overlay.repairText:Hide()
                                                if overlay.readyBtn and overlay.readyBtn.Enable then
                                                        -- cancel any in-progress hold when durability recovers
                                                        pcall(function() if overlay.CancelOverride then overlay:CancelOverride() end end)
                                                        overlay.readyBtn:Enable()
                                                        if overlay.readyBtn.hitbox then pcall(function() overlay.readyBtn.hitbox:Hide() end) end
                                                end
                                        end
                                        -- update mini view if showing
                                        if overlay.mini and overlay.mini:IsShown() then
                                               PopulateMini(overlay.mini)
                                        end
                        end)
                end
        end)

        -- Compact persistent mini overlay shown after the player responds (or if they initiated)
                local function CreateMiniOverlay(parent)
                if overlay.mini then return overlay.mini end
                -- Use UIParent as the mini overlay's parent so it remains visible
                -- even when the main `overlay` frame is hidden.
                local m = CreateFrame("Frame", addonName .. "ReadyMiniOverlay", UIParent, "BackdropTemplate")
                m:SetSize(240, 28)
                m:SetFrameStrata("HIGH")
                m:SetBackdrop({
                        bgFile = "Interface\\FriendsFrame\\UI-Toast-Background",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = false,
                        edgeSize = 8,
                })
                m:SetBackdropColor(0, 0, 0, 0.6)

                m.statusIcon = m:CreateTexture(nil, "ARTWORK")
                m.statusIcon:SetSize(18, 18)
                m.statusIcon:SetPoint("LEFT", 8, 0)

                m.durText = m:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
                m.durText:SetPoint("LEFT", m.statusIcon, "RIGHT", 8, 0)

                m.loadoutText = m:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                m.loadoutText:SetPoint("LEFT", m.durText, "RIGHT", 12, 0)
                m.loadoutText:SetWidth(120)
                m.loadoutText:SetJustifyH("LEFT")

                m:SetScript("OnShow", function(self)
                        self.updateTicker = 0
                end)

                m:SetScript("OnHide", function(self)
                        -- nothing for now; overlay cleanup handles watcher/timers
                end)

                m:Hide()
                overlay.mini = m
                return m
        end

                -- Populate a mini overlay's dynamic data (spec/loadout/durability/status)
                local function PopulateMini(mini)
                        pcall(function()
                                local specName, loadoutName = _G.RCPT_GetSpecAndLoadout()
                                local isLow, numLowSlots, avgDur = CheckLowDurability((TDB and TDB.MinDurabilityPercent) or 80)
                                local ok, status = pcall(GetReadyCheckStatus, "player")
                                if ok and status then
                                        if status == "ready" then
                                                mini.statusIcon:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
                                        elseif status == "notready" then
                                                mini.statusIcon:SetTexture("Interface\\Buttons\\UI-GroupLootPass")
                                        else
                                                mini.statusIcon:SetTexture(nil)
                                        end
                                else
                                        mini.statusIcon:SetTexture(nil)
                                end
                                if mini.durText then mini.durText:SetText(string.format("%d%%", math.floor((avgDur or 100) + 0.5))) end
                                if mini.loadoutText then mini.loadoutText:SetText(loadoutName) end
                        end)
                end

                -- allow external callers to create/show the mini overlay
                overlay.CreateMiniOverlay = function(self)
                        return CreateMiniOverlay(self)
                end

        function overlay:ShowForReadyCheck()
                -- Always center and hide Blizzard's ReadyCheckFrame so our overlay fully replaces it
                self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                local hid = pcall(function()
                        if ReadyCheckFrame and ReadyCheckFrame.IsShown and ReadyCheckFrame:IsShown() then
                                ReadyCheckFrame:Hide()
                                return true
                        end
                        return false
                end)
                self._hidDefault = hid
                -- ensure any prior override state isn't lingering when showing
                pcall(function() if self.CancelOverride then self:CancelOverride() end end)
                self:Show()

                -- If the player already responded (or is the initiator), show the compact mini view immediately
                do
                        local ok, status = pcall(GetReadyCheckStatus, "player")
                        if ok and status and (status == "ready" or status == "notready") then
                                local mini = CreateMiniOverlay(self)
                                mini:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                                -- hide the primary overlay entirely but keep watcher/timers alive
                                overlay._suppressOnHideClear = true
                                -- do not re-show Blizzard's ReadyCheckFrame later
                                overlay._hidDefault = nil
                                overlay:Hide()
                                -- fill mini
                                                PopulateMini(mini)
                                mini:Show()
                        end
                end

                if self._autoHideTimer then
                        self._autoHideTimer:Cancel()
                        self._autoHideTimer = nil
                end
                if not self.watcher then
                        local w = CreateFrame("Frame")
                        w:SetScript("OnEvent", function(_, event, ...)
                                if event == "READY_CHECK_FINISHED" then
                                                if overlay and overlay.Hide then
                                                        overlay:Hide()
                                                end
                                                -- also hide mini if present
                                                if overlay and overlay.mini and overlay.mini.Hide then
                                                        overlay.mini:Hide()
                                                end
                                                return
                                        end

                                        if event == "READY_CHECK_CONFIRM" then
                                                local unitOrName = select(1, ...)
                                                local isPlayerConfirm = false

                                                local ok1, res1 = pcall(function()
                                                        if Addon and Addon.SafeUnitIsUnit then return Addon.SafeUnitIsUnit(unitOrName, "player") end
                                                        if UnitIsUnit then local ok_, res_ = pcall(UnitIsUnit, unitOrName, "player"); if ok_ then return res_ end end
                                                        return false
                                                end)
                                                if ok1 and res1 then isPlayerConfirm = true end

                                                if not isPlayerConfirm then
                                                        local ok2, pname = pcall(UnitName, "player")
                                                        if ok2 and pname and unitOrName == pname then
                                                                isPlayerConfirm = true
                                                        end
                                                end

                                                if isPlayerConfirm then
                                                        -- show compact mini overlay to indicate player's response
                                                        local mini = CreateMiniOverlay(self)
                                                        if replaceDefault then
                                                                mini:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                                                        else
                                                                if ReadyCheckFrame then
                                                                        mini:SetPoint("BOTTOM", ReadyCheckFrame, "TOP", 0, 8)
                                                                else
                                                                        mini:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                                                                end
                                                        end
                                                        -- update contents once
                                                        PopulateMini(mini)

                                                                -- hide the primary overlay entirely but keep watcher/timers alive
                                                                overlay._suppressOnHideClear = true
                                                                -- ensure we won't re-show the default ReadyCheckFrame later
                                                                overlay._hidDefault = nil
                                                                overlay:Hide()
                                                                mini:Show()
                                                end
                                        end
                        end)
                        w:RegisterEvent("READY_CHECK_FINISHED")
                        w:RegisterEvent("READY_CHECK_CONFIRM")
                        self.watcher = w
                end
                if C_Timer then
                        if self._autoHideTimer then self._autoHideTimer:Cancel() self._autoHideTimer = nil end
                        self._autoHideTimer = C_Timer.NewTicker(30, function()
                                if overlay and overlay.Hide then overlay:Hide() end
                                if overlay and overlay._autoHideTimer then overlay._autoHideTimer:Cancel() overlay._autoHideTimer = nil end
                        end, 1)
                end
        end

                if ReadyCheckFrame then
                                ReadyCheckFrame:HookScript("OnShow", function()
                                                                        -- Always show our replacement overlay when Blizzard's ready-check frame appears
                                                                        overlay:ShowForReadyCheck()
                                                                end)

                                ReadyCheckFrame:HookScript("OnHide", function()
                                        overlay:Hide()
                                        end)
                end

        overlay:SetScript("OnHide", function(self)
                if self._suppressOnHideClear then
                        -- keep watcher/timers running and keep mini visible when we intentionally hide primary overlay
                        self._suppressOnHideClear = nil
                        return
                end
                -- ensure any override visuals / timers are cleared
                pcall(function() if self.CancelOverride then self:CancelOverride() end end)
                if self._autoHideTimer then
                        pcall(function() self._autoHideTimer:Cancel() end)
                        self._autoHideTimer = nil
                end
                if self.watcher then
                        pcall(function() self.watcher:UnregisterAllEvents(); self.watcher:SetScript("OnEvent", nil) end)
                        self.watcher = nil
                end
                if self.mini and self.mini.Hide then
                        pcall(function() self.mini:Hide() end)
                end
                if self._hidDefault then
                        pcall(function() if ReadyCheckFrame and ReadyCheckFrame.Show then ReadyCheckFrame:Show() end end)
                        self._hidDefault = nil
                end
                -- clear any temporary freeze/lock state so future ready checks behave normally
                pcall(function() self._freezeUntil = nil; self._overrideLocked = false; self._overrideReady = false; self._suspendPeriodic = nil end)
        end)

        overlay:Hide()
        return overlay
end

local function GetSpecAndLoadout()
        local specName = "Unknown Spec"
        local loadoutName = "Unknown Loadout"

        local specIndex = GetSpecialization()
        if specIndex and specIndex > 0 then
                local _, name = GetSpecializationInfo(specIndex)
                if name and name ~= "" then specName = name end
        end

        local got = false
        if PlayerUtil and PlayerUtil.GetCurrentSpecID then
                local ok, specID = pcall(PlayerUtil.GetCurrentSpecID)
                if ok and specID and C_ClassTalents and C_ClassTalents.GetLastSelectedSavedConfigID and C_Traits and C_Traits.GetConfigInfo then
                        local ok2, configID = pcall(C_ClassTalents.GetLastSelectedSavedConfigID, specID)
                        if ok2 and configID then
                                local info = C_Traits.GetConfigInfo(configID)
                                if info and info.name and info.name ~= "" then
                                        loadoutName = info.name
                                        got = true
                                end
                        end
                end
        end

        if not got and C_ClassTalents and C_ClassTalents.GetLastSelectedSavedConfigID then
                local ok, configID = pcall(C_ClassTalents.GetLastSelectedSavedConfigID, nil)
                if ok and configID and C_Traits and C_Traits.GetConfigInfo then
                        local info = C_Traits.GetConfigInfo(configID)
                        if info and info.name and info.name ~= "" then
                                loadoutName = info.name
                        end
                end
        end

        return specName, loadoutName
end

_G.RCPT_GetSpecAndLoadout = GetSpecAndLoadout

frame.changeTalentsButton = nil
frame.repairText = nil
frame.merchantHandler = nil

local function CreateChangeTalentsButton(parent, referenceButton)
        if frame.changeTalentsButton and frame.changeTalentsButton:IsShown() then return frame.changeTalentsButton end
        if not frame.changeTalentsButton then
                local btn = CreateFrame("Button", addonName .. "ChangeTalents", parent, "UIPanelButtonTemplate")
                btn:SetSize(referenceButton:GetWidth(), 24)
                btn:SetPoint("BOTTOM", referenceButton, "TOP", 0, 5)
                btn:SetText("Change Talents")
                btn:SetScript("OnClick", function()
                        if PlayerSpellsUtil and PlayerSpellsUtil.TogglePlayerSpellsFrame then
                                pcall(PlayerSpellsUtil.TogglePlayerSpellsFrame, 2)
                                return
                        end
                        if ToggleTalentFrame then
                                pcall(ToggleTalentFrame)
                                return
                        end
                        if PlayerTalentFrame and ShowUIPanel then
                                ShowUIPanel(PlayerTalentFrame)
                        end
                end)
                frame.changeTalentsButton = btn
        end
        frame.changeTalentsButton:Show()
        return frame.changeTalentsButton
end

local function ShowRepairText(parent, targetButton)
        if not frame.repairText then
                local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                fs:SetPoint("CENTER", targetButton, "CENTER")
                fs:SetTextColor(1, 0.1, 0.1)
                fs:SetShadowOffset(1, -1)
                fs:SetShadowColor(0, 0, 0, 1)
                frame.repairText = fs
        end
        frame.repairText:SetText("REPAIR NEEDED")
        frame.repairText:Show()
end

local function HideRepairText()
        if frame.repairText then frame.repairText:Hide() end
end

local function OnMerchantClosedRecheck(threshold, readyButton)
        local isLow = CheckLowDurability(threshold)
        if not isLow then
                if readyButton then readyButton:Show() end
                HideRepairText()
                if frame.merchantHandler then
                        frame.merchantHandler:UnregisterEvent("MERCHANT_CLOSED")
                        frame.merchantHandler:SetScript("OnEvent", nil)
                        frame.merchantHandler = nil
                end
        end
end

local function ReadyCheckHandler(initiator)
        if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        local threshold = (TDB and TDB.MinDurabilityPercent) or 80
        local isLow, numLowSlots, avgDur = CheckLowDurability(threshold)

        if TDB and TDB.SendPartyChatNotification then
                pcall(function()
                        local specName, loadoutName = _G.RCPT_GetSpecAndLoadout()
                        local channel = nil
                        if IsInRaid and IsInRaid() then channel = "RAID"
                        elseif IsInGroup and IsInGroup() then channel = "PARTY" end
                        if channel then
                                SendChatMessage("I am currently using talents: " .. (loadoutName or "Unknown Loadout"), channel)
                                if isLow then
                                        SendChatMessage(string.format("Current Durability: %d%%, Low Slots: %d", math.floor((avgDur or 100) + 0.5), numLowSlots or 0), channel)
                                end
                        end
                end)
        end

        CreateReadyOverlay()
        if overlay then
                overlay:ShowForReadyCheck()
                pcall(function()
                        local specName, loadoutName = _G.RCPT_GetSpecAndLoadout()
                        overlay.specText:SetText(specName or "Unknown Spec")
                        overlay.loadoutText:SetText(loadoutName or "Unknown Loadout")
                        overlay.durText:SetText(string.format(
                                "Durability: %d%% (%d low)",
                                math.floor((avgDur or 100) + 0.5),
                                numLowSlots or 0
                        ))

                        if isLow then
                                overlay.repairText:Show()
                                overlay.repairText:SetText("REPAIR NEEDED")

                                if overlay and overlay.readyBtn and overlay.readyBtn.Disable then
                                        local now = (GetTime and GetTime()) or 0
                                        if not overlay._freezeUntil or now >= overlay._freezeUntil then
                                                overlay.readyBtn:Disable()
                                                if overlay.readyBtn.hitbox then
                                                        pcall(function() overlay.readyBtn.hitbox:Show() end)
                                                end
                                        end
                                end
                        else
                                overlay.repairText:Hide()
                                if overlay and overlay.readyBtn and overlay.readyBtn.Enable then
                                        pcall(function()
                                                if overlay.CancelOverride then overlay:CancelOverride() end
                                        end)
                                        overlay.readyBtn:Enable()
                                        if overlay.readyBtn.hitbox then
                                                pcall(function() overlay.readyBtn.hitbox:Hide() end)
                                        end
                                end
                        end
                end)
                -- If the player initiated the ready check, force the compact mini overlay
                do
                                local ok, isInitiator = pcall(function()
                                                        if not initiator then return false end
                                                        if Addon and Addon.SafeUnitIsUnit then
                                                                if Addon.SafeUnitIsUnit(initiator, "player") then return true end
                                                        elseif UnitIsUnit then
                                                                local ok_, res_ = pcall(UnitIsUnit, initiator, "player")
                                                                if ok_ and res_ then return true end
                                                        end
                                                        local okn, pname = pcall(UnitName, "player")
                                                        if okn and pname and initiator == pname then return true end
                                                        return false
                                                end)
                                if ok and isInitiator then
                                        pcall(function()
                                                if overlay and overlay.CreateMiniOverlay then
                                                        local mini = overlay:CreateMiniOverlay(overlay)
                                                        mini:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                                                        -- ensure any in-progress override is cleared before hiding
                                                        pcall(function() if overlay and overlay.CancelOverride then overlay:CancelOverride() end end)
                                                        overlay._suppressOnHideClear = true
                                                        overlay._hidDefault = nil
                                                        overlay:Hide()
                                                        -- populate the mini overlay
                                                        local specName, loadoutName = _G.RCPT_GetSpecAndLoadout()
                                                        local isLow2, numLowSlots2, avgDur2 = CheckLowDurability((TDB and TDB.MinDurabilityPercent) or 80)
                                                        local ok2, st = pcall(GetReadyCheckStatus, "player")
                                                        if ok2 and st then
                                                                if st == "ready" then mini.statusIcon:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
                                                                elseif st == "notready" then mini.statusIcon:SetTexture("Interface\\Buttons\\UI-GroupLootPass")
                                                                else mini.statusIcon:SetTexture(nil) end
                                                        else
                                                                mini.statusIcon:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
                                                        end
                                                        if mini.durText then mini.durText:SetText(string.format("%d%%", math.floor((avgDur2 or 100) + 0.5))) end
                                                        if mini.loadoutText then mini.loadoutText:SetText(loadoutName) end
                                                        mini:Show()
                                                end
                                        end)
                                end
                end
                if isLow then
                        -- Replacement behavior: show repair state (do not disable Blizzard buttons)
                        if not frame.merchantHandler then
                                local h = CreateFrame("Frame")
                                h:RegisterEvent("MERCHANT_CLOSED")
                                h:SetScript("OnEvent", function()
                                        -- pass nil to avoid external manipulation of Blizzard button
                                        OnMerchantClosedRecheck(threshold, nil)
                                end)
                                frame.merchantHandler = h
                        end
                else
                        pcall(HideRepairText)
                        if frame.merchantHandler then
                                pcall(function()
                                        frame.merchantHandler:UnregisterEvent("MERCHANT_CLOSED")
                                        frame.merchantHandler:SetScript("OnEvent", nil)
                                        frame.merchantHandler = nil
                                end)
                        end
                end
        end
end

local function TalentEventHandler(self, event, ...)
        if event == "PLAYER_LOGIN" then
                if Addon and Addon.EnsureDefaults then
                        pcall(function() Addon:EnsureDefaults() end)
                else
                        if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
                end
        elseif event == "READY_CHECK" then
                ReadyCheckHandler(select(1, ...))
        end
end

local function ensureExports()
        _G.RCPT_TalentCheck = {
                CheckLowDurability = CheckLowDurability,
                GetSpecAndLoadout = GetSpecAndLoadout,
                TriggerReadyCheck = ReadyCheckHandler,
        }

        function _G.RCPT_TalentCheck.ShowReadyCheckDebug()
                if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
                pcall(ReadyCheckHandler)
                pcall(function()
                        if ReadyCheckFrame_Show then
                                ReadyCheckFrame_Show()
                        elseif ReadyCheckFrame and ReadyCheckFrame.Show then
                                ReadyCheckFrame:Show()
                        end
                end)
                pcall(function()
                        if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then
                                PlaySound(SOUNDKIT.READY_CHECK)
                        elseif PlaySound and SOUNDKIT and SOUNDKIT.UI_READY_CHECK then
                                PlaySound(SOUNDKIT.UI_READY_CHECK)
                        end
                end)
        end

        function _G.RCPT_TalentCheck.SimulateReadyCheckEvent()
                ReadyCheckHandler()
        end

        -- Helpers for manual testing: force start/complete the hold-to-override
        function _G.RCPT_TalentCheck.ForceStartOverride()
                pcall(function()
                        if overlay and overlay.StartOverride and overlay.readyBtn then
                                overlay:StartOverride(overlay.readyBtn)
                        end
                end)
        end

        function _G.RCPT_TalentCheck.ForceCompleteOverride()
                pcall(function()
                        if overlay and overlay.CompleteOverride then
                                overlay:CompleteOverride()
                        end
                end)
        end
end

local function InitTalentModule()
        -- restore event handler and exports
        frame:SetScript("OnEvent", TalentEventHandler)
        frame:RegisterEvent("PLAYER_LOGIN")
        frame:RegisterEvent("READY_CHECK")
        ensureExports()
        _G.RCPT_TalentActive = true
end

_G.RCPT_TalentInitialize = InitTalentModule

function Module.Init(addon)
                if addon and addon.talentDB then TDB = addon.talentDB end
                RefreshDB()
                InitTalentModule()
end

-- Register with core Addon registry if available, otherwise initialize immediately
if _G.RCPT and type(_G.RCPT.RegisterModule) == "function" then
        _G.RCPT:RegisterModule("TalentCheck", Module)
else
        InitTalentModule()
end

function _G.RCPT_TalentCheck.ShowReadyCheckDebug()
        if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        pcall(ReadyCheckHandler)
        pcall(function()
                if ReadyCheckFrame_Show then
                        ReadyCheckFrame_Show()
                elseif ReadyCheckFrame and ReadyCheckFrame.Show then
                        ReadyCheckFrame:Show()
                end
        end)
        pcall(function()
                if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then
                        PlaySound(SOUNDKIT.READY_CHECK)
                elseif PlaySound and SOUNDKIT and SOUNDKIT.UI_READY_CHECK then
                        PlaySound(SOUNDKIT.UI_READY_CHECK)
                end
        end)
end

function _G.RCPT_TalentCheck.SimulateReadyCheckEvent()
        ReadyCheckHandler()
end

local function TalentTeardown()
    if _G.RCPT_TalentCheck and _G.RCPT_TalentCheck.HideOverlay then
        pcall(_G.RCPT_TalentCheck.HideOverlay)
    end
    frame:UnregisterAllEvents()
    frame:SetScript("OnEvent", nil)
        if _G.RCPT_TalentCheck then
                _G.RCPT_TalentCheck = nil
        end
        Debug("TalentCheck module torn down.")
end

_G.RCPT_TalentTeardown = TalentTeardown
-- wrap teardown to clear active flag
local oldTalentTeardown = _G.RCPT_TalentTeardown
_G.RCPT_TalentTeardown = function(...)
        if oldTalentTeardown then pcall(oldTalentTeardown, ...) end
        _G.RCPT_TalentActive = false
end
