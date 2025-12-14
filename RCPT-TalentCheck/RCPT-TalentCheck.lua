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

RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}
db = RCPT_TalentCheckDB

-- Local debug wrapper that delegates to the global helper when available.
local function Debug(msg)
        if _G and _G.RCPT_Debug then
                _G.RCPT_Debug(msg)
        end
end

local function CheckLowDurability(threshold)
        threshold = threshold or (RCPT_TalentCheckDB and RCPT_TalentCheckDB.MinDurabilityPercent) or 80
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
        overlay.readyBtn:SetScript("OnClick", function()
                pcall(function() if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Click then ReadyCheckFrameYesButton:Click() elseif ReadyCheckFrameYesButton then ReadyCheckFrameYesButton:Disable(); ReadyCheckFrameYesButton:Enable() end end)
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
                self.updateTicker = self.updateTicker + elapsed
                if self.updateTicker >= 0.5 then
                        self.updateTicker = 0
                        local specName, loadoutName = _G.RCPT_GetSpecAndLoadout()
                        local isLow, numLowSlots, avgDur = CheckLowDurability(RCPT_TalentCheckDB.MinDurabilityPercent)
                        pcall(function()
                                                if not overlay.collapsed then
                                                        overlay.specText:SetText(specName)
                                                        overlay.loadoutText:SetText(loadoutName)
                                                        overlay.durText:SetText(string.format("Durability: %d%% (%d low)", math.floor(avgDur + 0.5), numLowSlots))
                                                end
                                        if isLow then
                                                overlay.repairText:Show()
                                                overlay.repairText:SetText("REPAIR NEEDED")
                                                if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Disable then
                                                        ReadyCheckFrameYesButton:Disable()
                                                end
                                        else
                                                overlay.repairText:Hide()
                                                if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Enable then
                                                        ReadyCheckFrameYesButton:Enable()
                                                end
                                        end
                        end)
                end
        end)

        function overlay:ShowForReadyCheck(replaceDefault)
                if replaceDefault then
                        self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                        local hid = pcall(function()
                                if ReadyCheckFrame and ReadyCheckFrame.IsShown and ReadyCheckFrame:IsShown() then
                                        ReadyCheckFrame:Hide()
                                        return true
                                end
                                return false
                        end)
                        self._hidDefault = hid
                else
                        if ReadyCheckFrame then
                                self:SetPoint("BOTTOM", ReadyCheckFrame, "TOP", 0, 8)
                        else
                                self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                        end
                end
                self:Show()

                if self._autoHideTimer then
                        self._autoHideTimer:Cancel()
                        self._autoHideTimer = nil
                end
                if not self.watcher then
                        local w = CreateFrame("Frame")
                        w:SetScript("OnEvent", function(_, event, ...)
                                if event == "READY_CHECK_FINISHED" then
                                        if overlay and overlay.Hide then overlay:Hide() end
                                        return
                                end

                                if event == "READY_CHECK_CONFIRM" then
                                        local unitOrName = select(1, ...)
                                        local isPlayerConfirm = false

                                        local ok1, res1 = pcall(function()
                                                if UnitIsUnit then return UnitIsUnit(unitOrName, "player") end
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
                                                if overlay and overlay.Hide then overlay:Hide() end
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
                        if RCPT_TalentCheckDB and RCPT_TalentCheckDB.ReplaceReadyCheck then
                                return
                        end
                        overlay:SetPoint("BOTTOM", ReadyCheckFrame, "TOP", 0, 8)
                        overlay:Show()
                end)

                ReadyCheckFrame:HookScript("OnHide", function()
                        if RCPT_TalentCheckDB and RCPT_TalentCheckDB.ReplaceReadyCheck then
                                return
                        end
                        overlay:Hide()
                        pcall(function() if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Enable then ReadyCheckFrameYesButton:Enable() end end)
                end)
        end

        overlay:SetScript("OnHide", function(self)
                if self._autoHideTimer then
                        pcall(function() self._autoHideTimer:Cancel() end)
                        self._autoHideTimer = nil
                end
                if self.watcher then
                        pcall(function() self.watcher:UnregisterAllEvents(); self.watcher:SetScript("OnEvent", nil) end)
                        self.watcher = nil
                end
                if self._hidDefault then
                        pcall(function() if ReadyCheckFrame and ReadyCheckFrame.Show then ReadyCheckFrame:Show() end end)
                        self._hidDefault = nil
                end
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

local function ReadyCheckHandler()
        if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        local threshold = (RCPT_TalentCheckDB and RCPT_TalentCheckDB.MinDurabilityPercent) or 80
        local isLow, numLowSlots, avgDur = CheckLowDurability(threshold)

        if RCPT_TalentCheckDB and RCPT_TalentCheckDB.SendPartyChatNotification then
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
                local replace = RCPT_TalentCheckDB and RCPT_TalentCheckDB.ReplaceReadyCheck
                overlay:ShowForReadyCheck(replace)
                pcall(function()
                        local specName, loadoutName = _G.RCPT_GetSpecAndLoadout()
                        overlay.specText:SetText(specName or "Unknown Spec")
                        overlay.loadoutText:SetText(loadoutName or "Unknown Loadout")
                        overlay.durText:SetText(string.format("Durability: %d%% (%d low)", math.floor((avgDur or 100) + 0.5), numLowSlots or 0))
                        if isLow then
                                overlay.repairText:Show()
                                overlay.repairText:SetText("REPAIR NEEDED")
                                if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Disable then
                                        ReadyCheckFrameYesButton:Disable()
                                end
                        else
                                overlay.repairText:Hide()
                                if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Enable then
                                        ReadyCheckFrameYesButton:Enable()
                                end
                        end
                end)

                if isLow then
                        if not replace then
                                if ReadyCheckFrame and ReadyCheckFrameNoButton then
                                        pcall(CreateChangeTalentsButton, ReadyCheckFrame, ReadyCheckFrameNoButton)
                                end
                                pcall(function() if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Hide then ReadyCheckFrameYesButton:Hide() end end)
                                pcall(ShowRepairText, ReadyCheckFrame, ReadyCheckFrameYesButton)
                        else
                                pcall(function() if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Disable then ReadyCheckFrameYesButton:Disable() end end)
                        end

                        if not frame.merchantHandler then
                                local h = CreateFrame("Frame")
                                h:RegisterEvent("MERCHANT_CLOSED")
                                h:SetScript("OnEvent", function()
                                        OnMerchantClosedRecheck(threshold, ReadyCheckFrameYesButton)
                                end)
                                frame.merchantHandler = h
                        end
                else
                        if not (RCPT_TalentCheckDB and RCPT_TalentCheckDB.ReplaceReadyCheck) then
                                pcall(function() if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Show then ReadyCheckFrameYesButton:Show() end end)
                                pcall(HideRepairText)
                        else
                                pcall(HideRepairText)
                                pcall(function() if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Enable then ReadyCheckFrameYesButton:Enable() end end)
                        end
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
                if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        elseif event == "READY_CHECK" then
                ReadyCheckHandler()
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
                        if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Show then ReadyCheckFrameYesButton:Show() end
                        if ReadyCheckFrameNoButton and ReadyCheckFrameNoButton.Show then ReadyCheckFrameNoButton:Show() end
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

-- initialize at load time
InitTalentModule()

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
                if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Show then ReadyCheckFrameYesButton:Show() end
                if ReadyCheckFrameNoButton and ReadyCheckFrameNoButton.Show then ReadyCheckFrameNoButton:Show() end
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
