# RCPT
## Ready Check, Pull Timer & TalentCheck

RCPT manages ready checks and pull timers and includes a built-in TalentCheck overlay to augment the ReadyCheck experience.

Installation & enablement:
- Ensure the `RCPT` folder is in your `Interface/AddOns` directory.
- Enable the addon in the AddOns list on the character select screen and reload the UI with `/reload` after changes.

Testing the TalentCheck overlay (preferred via Interface Options):
- Open `Interface -> AddOns -> RCPT` and use the **Test Ready Overlay** button to preview behavior.

Quick runtime/debug helpers (chat / macro window):
- Show the ReadyCheck UI and play the ready-check sound:
	- `/run RCPT_TalentCheck.ShowReadyCheckDebug()`
- Invoke the ReadyCheck handler without a game event:
	- `/run RCPT_TalentCheck.SimulateReadyCheckEvent()`
- Check durability directly from Lua and print results:
	- `/run local isLow, lowSlots, avg = RCPT_TalentCheck.CheckLowDurability(80); print(isLow, lowSlots, avg)`

Behavior notes:
- During ready checks the overlay shows your current spec and loadout, plus durability summary. If an item is below the configured threshold the overlay (or default frame) will display "REPAIR NEEDED" and disable the Ready button until durability is restored.
- Use `Interface -> AddOns -> RCPT` to configure `MinDurabilityPercent`, toggle `ReplaceReadyCheck`, and enable party notifications.

Compatibility:
- The addon wraps risky UI modifications in `pcall` to minimize taint. If you experience issues, try disabling other addons that also change the ReadyCheck UI.


