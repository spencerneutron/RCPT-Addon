# RCPT
## Ready Check, Pull Timer

Initiates a ready check, waits for all players to be ready, and sends a pull timer.

## TalentCheck (testing)

Quick testing instructions for the `TalentCheck.lua` scaffolding added to the addon:

- Install: Ensure the `RCPT` folder is in your `Interface/AddOns` directory (it already is).
- Enable: At the character select screen make sure `RCPT` is enabled in the AddOns list and reload UI with `/reload` after changes.
- Manual checks from the chat window:
	- Initialize the saved vars (optional):
		- `/run RCPT_TalentCheck.EnsureDB()`
	- Check durability directly and print results:
		- `/run local isLow, lowSlots, avg = RCPT_TalentCheck.CheckLowDurability(80); print(isLow, lowSlots, avg)`
	- Trigger the ReadyCheck handler manually (for UI testing):
		- `/run RCPT_TalentCheck.TriggerReadyCheck()`

- In-game workflow:
	- Join a party or raid and have the leader start a Ready Check. The addon will modify the Ready Check UI, show the loadout/spec, and (if an item is below the threshold) hide the Ready button and display "REPAIR NEEDED".
	- If you want party notifications, enable `SendPartyChatNotification` in the addon's saved variables (via saved-vars or an in-game config you add later). If enabled the addon will send a short message to party chat with loadout and durability info.

Notes:
- Some UI changes are best-effort and wrapped in `pcall` to avoid taint/protection errors. If you see unexpected behavior, check the default UI and disable other addons that modify the Ready Check frame.

