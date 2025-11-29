-- Documenting old WeakAura behavior:

-- Trigger: Event -> READY_CHECK
-- Condition: None
-- Action:
--  OnInit:

        -- aura_env.CheckLowDurability = function (threshold)
        --     local numLowSlots = 0
        --     local totalDurability = 0
        --     local numSlotsWithDurability = 0
            
        --     -- Loop through all relevant equipment slots
        --     for slot = 1, 17 do
        --         local current, maximum = GetInventoryItemDurability(slot)
        --         if current and maximum then
        --             local durabilityPercent = (current / maximum) * 100
        --             totalDurability = totalDurability + durabilityPercent
        --             numSlotsWithDurability = numSlotsWithDurability + 1
                    
        --             if durabilityPercent < threshold then
        --                 numLowSlots = numLowSlots + 1
        --             end
        --         end
        --     end
            
        --     -- Calculate average durability
        --     local averageDurability = numSlotsWithDurability > 0 and (totalDurability / numSlotsWithDurability) or 100
            
        --     -- Return if any item is below the threshold, the count of low slots, and the average durability
        --     local isLow = numLowSlots > 0
        --     return isLow, numLowSlots, averageDurability
        -- end

        -- _G.STRCEnv = aura_env

-- OnShow:

        -- local specID = PlayerUtil.GetCurrentSpecID()
        -- local specName = GetSpecializationNameForSpecID(specID) or "Unknown Spec"
        -- local configID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
        -- local configInfo = C_Traits.GetConfigInfo(configID)
        -- local loadoutName = configInfo and configInfo.name or "Unknown Loadout"

        -- local threshold = _G.STRCEnv.config["MinDurabilityPercent"] or 80  -- Default to 80% if not set
        -- local isLow, numLowSlots, averageDurability = _G.STRCEnv.CheckLowDurability(threshold)

        -- -- Modify ReadyCheckFrame's size (reduce by 20 from previous height)
        -- ReadyCheckFrame:SetHeight(160)  -- Reduced height by 20 (original was 180)

        -- -- Modify the text and add color/size to specName
        -- local specText = "|cFFFFFF00" .. specName .. "|r"  -- Yellow color for specName
        -- local targetIcon = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:16|t"  -- Green triangle icon, size 16
        -- local loadoutText = targetIcon .. " " .. loadoutName .. " " .. targetIcon  -- Surround the loadout name with the green triangle icon

        -- -- Adjust the text size and format in the ReadyCheckFrameText
        -- ReadyCheckFrameText:SetFont("GameFontNormalLarge", 16)  -- Adjust the font size to make the text more visible
        -- ReadyCheckFrameText:SetText("Current Spec: " .. specText .. "\n" .. "Current Loadout: " .. loadoutText)

        -- -- Adjust Yes and No button sizes and modify text
        -- ReadyCheckFrameYesButton:SetHeight(65)  -- Increase button height further to fit the new text
        -- ReadyCheckFrameYesButton:SetText(loadoutName .. "\n" .. "|cFF00FF00Ready|r")

        -- -- Modify ReadyCheckFrameNoButton to remove "Change Talents" text
        -- ReadyCheckFrameNoButton:SetHeight(30)
        -- ReadyCheckFrameNoButton:SetText("|cFFFF0000Not Ready|r")

        -- -- Create a new button for "Change Talents"
        -- local changeTalentsButton = CreateFrame("Button", nil, ReadyCheckFrame, "UIPanelButtonTemplate")
        -- changeTalentsButton:SetPoint("BOTTOM", ReadyCheckFrameNoButton, "TOP", 0, 5)  -- Position it above the "No" button
        -- changeTalentsButton:SetSize(ReadyCheckFrameNoButton:GetWidth(), 30)  -- Match width, set desired height
        -- changeTalentsButton:SetText("Change Talents")

        -- -- Function to open Talent frame when "Change Talents" button is clicked
        -- changeTalentsButton:SetScript("OnClick", function()
        --         -- Open the Talent UI
        --         PlayerSpellsUtil.TogglePlayerSpellsFrame(2)  -- This opens the Talent UI in the current WoW version
        -- end)

        -- -- Clean up button when the ReadyCheckFrame hides
        -- ReadyCheckFrame:HookScript("OnHide", function()
        --         changeTalentsButton:Hide()  -- Hide the button
        --         -- Optionally, you can also release resources if needed
        --         changeTalentsButton:SetScript("OnClick", nil)
        -- end)

        -- if isLow then
        --     -- Hide the Ready button and display "REPAIR NEEDED"
        --     ReadyCheckFrameYesButton:Hide()
            
        --     if not _G.STRCEnv.repairText then
        --         _G.STRCEnv.repairText = ReadyCheckFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        --         _G.STRCEnv.repairText:SetPoint("CENTER", ReadyCheckFrameYesButton, "CENTER")  -- Position it where the Yes button is
        --         _G.STRCEnv.repairText:SetTextColor(1, 0.1, 0.1)  -- Brighter red color for emphasis
        --         _G.STRCEnv.repairText:SetShadowOffset(1, -1)  -- Add a small shadow for contrast
        --         _G.STRCEnv.repairText:SetShadowColor(0, 0, 0, 1)  -- Black shadow for contrast
                
        --         -- Set frame strata to make sure text is on top
        --         ReadyCheckFrame:SetFrameStrata("HIGH")  -- Move the entire frame to a higher strata
        --         _G.STRCEnv.repairText:SetDrawLayer("OVERLAY", 7)  -- Ensure it's on top within the frame
        --     end
            
        --     _G.STRCEnv.repairText:SetText("REPAIR NEEDED")
        --     _G.STRCEnv.repairText:Show()
            
        --     -- Create the frame and register the event
        --     local frame = CreateFrame("Frame")
            
        --     -- Store necessary values in local variables and pass them explicitly to the event handler
        --     _G.STRCEnv.OnMerchantClosed = function (threshold, repairText, ReadyCheckFrameYesButton)
        --         -- Re-check durability
        --         local isLowUpdated, _, avgDurabilityUpdated = _G.STRCEnv.CheckLowDurability(threshold)
                
        --         -- If durability has improved beyond the threshold, restore the "Ready" button and hide "REPAIR NEEDED"
        --         if not isLowUpdated then
        --             ReadyCheckFrameYesButton:Show()  -- Show the Ready button
        --             if repairText then
        --                 repairText:Hide()  -- Hide the repair text
        --             end
        --             -- Unregister the event once done
        --             _G.STRCEnv.HandlerFrame:UnregisterEvent("MERCHANT_CLOSED")
        --             _G.STRCEnv.HandlerFrame = nil
        --         end
        --     end
            
        --     local repairTextRef = _G.STRCEnv.repairText
            
        --     frame:RegisterEvent("MERCHANT_CLOSED")
            
        --     -- Set the script with the explicitly passed values
        --     frame:SetScript("OnEvent", function()
        --             _G.STRCEnv.OnMerchantClosed(threshold, repairTextRef, ReadyCheckFrameYesButton)
        --     end)
            
        --     _G.STRCEnv.HandlerFrame = frame
        -- else
        --     -- Ensure the Ready button is visible and "REPAIR NEEDED" is hidden
        --     ReadyCheckFrameYesButton:Show()
            
        --     if _G.STRCEnv.repairText then
        --         _G.STRCEnv.repairText:Hide()
        --     end
        -- end

        -- -- Fallback output to the currently active chat tab
        -- local activeChatFrame = SELECTED_DOCK_FRAME or DEFAULT_CHAT_FRAME
        -- activeChatFrame:AddMessage(string.format("Current Spec: %s", specName))
        -- activeChatFrame:AddMessage(string.format("Current Loadout: %s", loadoutName))

        -- if (_G.STRCEnv.config["SendPartyChatNotification"]) then
        --     -- Send a message to party chat
        --     SendChatMessage("I am currently using talents: " .. loadoutName, "PARTY")
        --     if isLow then
        --         SendChatMessage(string.format("Current Durability: %d%%, Low Slots: %d", math.floor(averageDurability + 0.5), numLowSlots), "PARTY")
        --     end
        -- end

-- Custom Options:
    -- SendPartyChatNotification (boolean) - Send party chat notification with current loadout name
    -- MinDurabilityPercent (number) - Minimum durability percentage threshold to trigger "REPAIR NEEDED" display
        -- default 80, min 5 max 100 step 5


-- End of old WeakAura behavior documentation

-- Scaffolding implementation: convert documented WeakAura behavior
-- into addon-style behavior. This file registers a READY_CHECK
-- listener, checks equipment durability, adjusts the ReadyCheck UI,
-- and provides a "Change Talents" button plus optional party chat.

local addonName = "RCPT"

-- Saved variables (uses global saved var `RCPT_TalentCheckDB`)
RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}
local db = RCPT_TalentCheckDB

-- Defaults are consolidated in `config.lua` (RCPT_TalentCheckDefaults)
-- Ensure local reference to the saved-vars table exists
RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}
db = RCPT_TalentCheckDB

-- Check durability across equipment slots 1..17
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

-- Helper to safely get spec name and an available 'loadout' name
local function GetSpecAndLoadout()
        local specName = "Unknown Spec"
        local loadoutName = "Unknown Loadout"

        local specIndex = GetSpecialization()
        if specIndex and specIndex > 0 then
                local _, name = GetSpecializationInfo(specIndex)
                if name and name ~= "" then specName = name end
        end

        -- Try new talent APIs for loadout name when available
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

        -- Fallback to saved talent loadout name from talent APIs (best-effort)
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

-- Keep references to created UI elements so we don't duplicate them
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
                        -- Try modern API, fall back gracefully
                        if PlayerSpellsUtil and PlayerSpellsUtil.TogglePlayerSpellsFrame then
                                pcall(PlayerSpellsUtil.TogglePlayerSpellsFrame, 2)
                                return
                        end
                        if ToggleTalentFrame then
                                pcall(ToggleTalentFrame)
                                return
                        end
                        -- As last resort, try to open PlayerTalentFrame if present
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
        -- Re-check durability when merchant closed and restore UI if repaired
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

        -- Modify ReadyCheckFrame appearance (best-effort; don't error if globals missing)
        if ReadyCheckFrame and ReadyCheckFrameText then
                pcall(ReadyCheckFrame.SetHeight, ReadyCheckFrame, 160)

                local specName, loadoutName = GetSpecAndLoadout()
                local specText = "|cFFFFFF00" .. specName .. "|r"
                local targetIcon = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:16|t"
                local loadoutText = targetIcon .. " " .. loadoutName .. " " .. targetIcon

                -- Best-effort: only set text/font if methods present
                pcall(ReadyCheckFrameText.SetFont, ReadyCheckFrameText, "GameFontNormalLarge", 16)
                pcall(ReadyCheckFrameText.SetText, ReadyCheckFrameText, "Current Spec: " .. specText .. "\n" .. "Current Loadout: " .. loadoutText)

                if ReadyCheckFrameYesButton then
                        pcall(ReadyCheckFrameYesButton.SetHeight, ReadyCheckFrameYesButton, 65)
                        pcall(ReadyCheckFrameYesButton.SetText, ReadyCheckFrameYesButton, loadoutName .. "\n" .. "|cFF00FF00Ready|r")
                end
                if ReadyCheckFrameNoButton then
                        pcall(ReadyCheckFrameNoButton.SetHeight, ReadyCheckFrameNoButton, 30)
                        pcall(ReadyCheckFrameNoButton.SetText, ReadyCheckFrameNoButton, "|cFFFF0000Not Ready|r")
                end

                -- Create Change Talents button and hook hiding
                if ReadyCheckFrameNoButton then
                        local changeBtn = CreateChangeTalentsButton(ReadyCheckFrame, ReadyCheckFrameNoButton)
                        ReadyCheckFrame:HookScript("OnHide", function()
                                if changeBtn then changeBtn:Hide() end
                        end)
                end

                if isLow then
                        if ReadyCheckFrameYesButton then ReadyCheckFrameYesButton:Hide() end
                        ShowRepairText(ReadyCheckFrame, ReadyCheckFrameYesButton or ReadyCheckFrame)

                        -- Register MERCHANT_CLOSED handler that re-checks durability
                        if not frame.merchantHandler then
                                local h = CreateFrame("Frame")
                                h:RegisterEvent("MERCHANT_CLOSED")
                                h:SetScript("OnEvent", function()
                                        OnMerchantClosedRecheck(threshold, ReadyCheckFrameYesButton)
                                end)
                                frame.merchantHandler = h
                        end
                else
                        if ReadyCheckFrameYesButton then ReadyCheckFrameYesButton:Show() end
                        HideRepairText()
                end

                -- Chat outputs
                local activeChatFrame = SELECTED_DOCK_FRAME or DEFAULT_CHAT_FRAME
                if activeChatFrame and activeChatFrame.AddMessage then
                        activeChatFrame:AddMessage(string.format("Current Spec: %s", specName))
                        activeChatFrame:AddMessage(string.format("Current Loadout: %s", loadoutName))
                        if isLow then
                                activeChatFrame:AddMessage(string.format("Durability: %d%%, Low Slots: %d", math.floor(avgDur + 0.5), numLowSlots))
                        end
                end

                if db.SendPartyChatNotification then
                        local _, loadoutName = GetSpecAndLoadout()
                        if UnitInParty("player") or UnitInRaid("player") then
                                pcall(SendChatMessage, "I am currently using talents: " .. (loadoutName or "Unknown"), "PARTY")
                                if isLow then
                                        pcall(SendChatMessage, string.format("Current Durability: %d%%, Low Slots: %d", math.floor(avgDur + 0.5), numLowSlots), "PARTY")
                                end
                        end
                end
        end
end

-- Event dispatcher
frame:SetScript("OnEvent", function(self, event, ...)
        if event == "PLAYER_LOGIN" then
                if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        elseif event == "READY_CHECK" then
                ReadyCheckHandler()
        end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("READY_CHECK")

-- Expose some helpers for interactive testing in-game
_G.RCPT_TalentCheck = {
        CheckLowDurability = CheckLowDurability,
        GetSpecAndLoadout = GetSpecAndLoadout,
        TriggerReadyCheck = ReadyCheckHandler,
}

-- Debug helpers
-- Show the ReadyCheckFrame and apply this addon's ReadyCheck styling without an actual ready check.
function _G.RCPT_TalentCheck.ShowReadyCheckDebug()
        if RCPT_InitDefaults then pcall(RCPT_InitDefaults) end
        -- Run the handler to apply text/buttons/repair logic
        pcall(ReadyCheckHandler)

        -- Try to show the Blizzard ReadyCheckFrame if available, otherwise just show the frame object
        pcall(function()
                if ReadyCheckFrame_Show then
                        ReadyCheckFrame_Show() -- Blizzard UI function if present
                elseif ReadyCheckFrame and ReadyCheckFrame.Show then
                        ReadyCheckFrame:Show()
                end
        end)

        -- Ensure Yes/No buttons are visible when showing from debug
        pcall(function()
                if ReadyCheckFrameYesButton and ReadyCheckFrameYesButton.Show then ReadyCheckFrameYesButton:Show() end
                if ReadyCheckFrameNoButton and ReadyCheckFrameNoButton.Show then ReadyCheckFrameNoButton:Show() end
        end)

        -- Play the ready check sound (best-effort)
        pcall(function()
                if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then
                        PlaySound(SOUNDKIT.READY_CHECK)
                elseif PlaySound and SOUNDKIT and SOUNDKIT.UI_READY_CHECK then
                        PlaySound(SOUNDKIT.UI_READY_CHECK)
                end
        end)
end

-- Simulate the READY_CHECK event by invoking the frame's event handler.
-- This will call the same code path as when the game sends READY_CHECK.
function _G.RCPT_TalentCheck.SimulateReadyCheckEvent()
        -- If the frame has the OnEvent script, call it with the READY_CHECK event
        ReadyCheckHandler()
end