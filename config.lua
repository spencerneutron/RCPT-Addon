RCPT_Config = RCPT_Config or {}

RCPT_Defaults = {
    pullDuration = 10,
    cancelKeywords = { "stop", "wait", "hold" },
    retryTimeout = 15,
    maxRetries = 2,
    debug = true,
    configVersion = 1
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
end
