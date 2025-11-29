RCPT_Config = RCPT_Config or {}

RCPT_Defaults = {
    pullDuration = 10,
    cancelKeywords = { "stop", "wait", "hold" },
    retryTimeout = 15,
    maxRetries = 2,
    debug = true,
    configVersion = 1
}

-- TalentCheck defaults consolidated here so all addon defaults live in one file
RCPT_TalentCheckDefaults = {
    SendPartyChatNotification = false,
    MinDurabilityPercent = 80,
    -- If true, hide the default Blizzard ReadyCheckFrame and show our overlay centered
    ReplaceReadyCheck = true,
}

function RCPT_InitDefaults()
    RCPT_Config = RCPT_Config or {}

    if RCPT_Config.configVersion ~= RCPT_Defaults.configVersion then
        -- Full reset or migration logic
        RCPT_Config = CopyTable(RCPT_Defaults)
        print("|cff00ccff[RCPT]|r Config updated to version", RCPT_Defaults.configVersion)
        return
    end

    for k, v in pairs(RCPT_Defaults) do
        if RCPT_Config[k] == nil then
            RCPT_Config[k] = v
        end
    end

    -- Ensure talent-check saved vars exist and apply defaults
    RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}
    for k, v in pairs(RCPT_TalentCheckDefaults) do
        if RCPT_TalentCheckDB[k] == nil then
            RCPT_TalentCheckDB[k] = v
        end
    end
    -- expose consolidated settings table for convenience
    RCPT_Settings = RCPT_Settings or {}
    RCPT_Settings.config = RCPT_Config
    RCPT_Settings.talentCheck = RCPT_TalentCheckDB
end