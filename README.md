### [Get it on Wago](https://addons.wago.io/addons/rcpt-addon)
### [Get it on CurseForge](https://www.curseforge.com/wow/addons/ready-check-pull-timer)
### [Get it on GitHub](https://github.com/spencerneutron/RCPT-Addon/releases)


# RCPT
RCPT is a World of Warcraft addon focused on one job: turning ready checks into a cleaner pull workflow.

It combines automated pull timers, a dedicated pull-status UI, and a TalentCheck-ready overlay that surfaces the information raid leaders and players actually need before a pull.

---

## Features

### Pull Timer Automation ```/rcpt```

- Starts a pull timer automatically when the ready check passes.
- Tracks confirmations against the active group and supports retry logic when a check fails.
- Supports cancel keywords for fast pull cancellation when the raid needs to stop or hold.

### Pull Timer UI

- Displays a compact status frame for the ready-check and pull sequence.
- Shows the current stage at a glance, including ready check sent, waiting, result, and pull timer progress.
- Persists its position and can anchor around the ready-check overlay when relevant.

### Rapid Mode ```/rcpt rapid```

- Built for rapid progression retries where the raid needs to chain pulls with minimal downtime, automatically beginning after combat finishes.
- Runs a longer rolling countdown, sends the ready check automatically at the right point, and cancels before pull if the raid is not ready.
- Supports defer, restart, skip-forward, and stop controls so the group can recover quickly between attempts.

### Talent Check

- Adds a ready-check overlay that shows your current spec, loadout, and durability summary.
- Flags low durability clearly and can gate the Ready response until gear is repaired.
- Includes direct Ready, Not Ready, and Change Talents actions from the overlay.
- Can report talent and readiness information through chat, depending on your selected report mode.

TalentCheck grew out of an earlier WeakAura concept maintained by the addon author: https://wago.io/CBDoKxZdQ

---

## Important Settings

RCPT has a full options panel, but these are the settings most players will care about:

- Pull timer duration.
- Rapid Mode duration and skip target.
- Durability threshold for TalentCheck warnings.
- Whether the TalentCheck overlay replaces the default Ready Check frame.
- Raid and party report mode for TalentCheck output.

---

## Installation

1. Download the latest release.
2. Extract the addon folders into your World of Warcraft `Interface/AddOns` directory.

---

## Notes

- Legacy slash commands remain available for compatibility.
- RCPT uses protected-UI-safe patterns where possible to reduce taint risk around ready-check interactions.

