-- Compatibility shim: core Addon provides defaults, migrations, and EnsureDefaults.
RCPT_Config = RCPT_Config or {}
RCPT_TalentCheckDB = RCPT_TalentCheckDB or {}

if RCPT_InitDefaults then
    pcall(RCPT_InitDefaults)
end

-- Default: disable automatic pull timer behavior unless explicitly enabled
if RCPT_Config.enableAutoPullTimers == nil then
    RCPT_Config.enableAutoPullTimers = false
end
