# RCPT
### Ready Check, Pull Timer + TalentCheck

RCPT is a lightweight World of Warcraft addon for managing ready checks and pull timers, now extended with a built-in TalentCheck ReadyCheck overlay that shows your spec, loadout, and equipment durability during ready checks.

The addon still includes legacy slash commands for backwards compatibility, but configuration and testing are now supported via the Blizzard Interface Options: `Interface -> AddOns -> RCPT` (preferred).

---

## 🔧 New: TalentCheck ReadyCheck Overlay

- Shows your current specialization and loadout name during Ready Checks.
- Displays overall durability and how many equipment slots are below the configured threshold.
- If an item is below the threshold, the overlay will display a prominent "REPAIR NEEDED" message and (optionally) disable the Ready button until durability is restored.
- Includes a "Change Talents" button (opens the talent UI) and easy-to-use Ready / Not Ready controls.
- Optionally replaces the default Blizzard ReadyCheck frame. Toggle this behavior in `Interface -> AddOns -> RCPT`.

These features are an evolution of a WeakAura I previously maintained (original reference: https://wago.io/CBDoKxZdQ) and have been reworked into an addon-friendly implementation.

---

## ⚙️ Configuration (preferred)

- Open `Interface -> AddOns -> RCPT` to change TalentCheck options:
  - `ReplaceReadyCheck`: when enabled, the addon centers a compact overlay and hides the default ReadyCheck frame.
  - `MinDurabilityPercent`: durability threshold that triggers the "REPAIR NEEDED" behavior.
  - `SendPartyChatNotification`: whether to send a short party message with loadout/durability information.

Configuration changes made in the Interface Options persist across reloads.

---

## 🧪 Quick Testing & Debugging

- Use the in-panel **Test Ready Overlay** button in `Interface -> AddOns -> RCPT` to preview the ReadyCheck overlay.
- Runtime helper functions available for testing from the chat / macro window:
  - `/run RCPT_TalentCheck.ShowReadyCheckDebug()` — show the ReadyCheck UI and play the ready-check sound (best-effort).
  - `/run RCPT_TalentCheck.SimulateReadyCheckEvent()` — invokes the ReadyCheck handler without triggering the Blizzard event.
  - `/run local isLow, lowSlots, avg = RCPT_TalentCheck.CheckLowDurability(80); print(isLow, lowSlots, avg)` — quick durability check from Lua.

Legacy slash commands (still available): `/rcpt` and related subcommands. These remain supported but are no longer the recommended configuration workflow.

---

## 📦 Installation

1. Download the latest from the GitHub Releases page.
2. Extract and place the `RCPT/` folder into your WoW AddOns directory.

---

## Credits & Notes

- TalentCheck features adapted from a WeakAura previously maintained by the addon author (https://wago.io/CBDoKxZdQ).
- The addon avoids protected UI calls and wraps best-effort changes in `pcall` to reduce taint risk. If you notice issues, try disabling other addons that modify the ReadyCheck frame.

