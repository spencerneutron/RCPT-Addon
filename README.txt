# RCPT
## Ready Check, Pull Timer & TalentCheck

RCPT manages ready checks and pull timers and includes a built-in TalentCheck overlay to augment the ReadyCheck experience.

Installation & enablement:
- Ensure the `RCPT` folder is in your `Interface/AddOns` directory.
- Enable the addon in the AddOns list on the character select screen and reload the UI with `/reload` after changes.

Options panel:
- Open it with `/rcpt options` (also `config`, `opt`), from `Options -> AddOns -> RCPT`, or from the RCPT entry in the addon compartment.

Testing the TalentCheck overlay and pull frame (preferred via the options panel):
- In the Tools section, use **Test ready check** to preview the overlay, **Preview pull frame** (or `/rcpt preview`) to demo the pull timer frame, and **Reset frame positions** to put the pull timer and ready check frames back at their default positions.
- The Appearance section sets the frame scale and can lock the frames so they cannot be dragged.

Rapid Mode (`/rcpt rapid`):
- Built for progression retries: the raid chains pulls with minimal downtime, and a new countdown starts automatically after combat finishes.
- Runs a longer rolling countdown, sends the ready check automatically at the right point, and cancels before the pull if the raid is not ready.
- Supports defer, restart, skip-forward, and stop controls (`/rcpt rapid skip|defer|restart|stop`).
- Start or stop a session with `/rcpt rapid`, the **Rapid Mode session** button in the options panel, or a right-click on RCPT in the addon compartment. You must be the group leader or an assistant.

Quick runtime/debug helpers (chat / macro window):
- Show the ReadyCheck UI and play the ready-check sound:
	- `/run RCPT_TalentCheck.ShowReadyCheckDebug()`
- Invoke the ReadyCheck handler without a game event:
	- `/run RCPT_TalentCheck.SimulateReadyCheckEvent()`
- Check durability directly from Lua and print results:
	- `/run local isLow, lowSlots, avg = RCPT_TalentCheck.CheckLowDurability(80); print(isLow, lowSlots, avg)`

Behavior notes:
- During ready checks the overlay shows your current spec and loadout, plus durability summary. If an item is below the configured threshold the overlay (or default frame) will display "REPAIR NEEDED" and disable the Ready button until durability is restored.
- Use the options panel to configure the minimum durability, toggle replacing the default ready check, and choose the party and raid report modes.

Compatibility:
- The addon wraps risky UI modifications in `pcall` to minimize taint. If you experience issues, try disabling other addons that also change the ReadyCheck UI.


