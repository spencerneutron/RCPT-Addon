-- RCPT.lua
local f = CreateFrame("Frame")
local retryCount = 0
local readyMap = {}
local scheduledCleanup = nil
local initiatedByMe = false

RCPT_InitDefaults()
-- RCPT.lua (shim)
-- This repository now uses a bootstrap + modular structure.
-- The core runtime has moved to `RCPT-Main/RCPT-Main.lua` and the talent UI
-- to `RCPT-TalentCheck/RCPT-TalentCheck.lua` (both are LoadOnDemand addons).

print("[RCPT] Legacy RCPT.lua is now a shim. Use the bootstrap (this folder) which will load RCPT-Main when relevant.")
-- Keep this file as a harmless shim to avoid duplicate execution if loaded accidentally.
end
