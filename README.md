### [Get it on Wago](https://addons.wago.io/addons/rcpt-addon)

# RCPT
### Ready Check, Pull Timer

**RCPT** is a lightweight command-line World of Warcraft addon that helps raid leaders and dungeon organizers run smoother encounters. It automates the process of initiating a ready check, monitoring player responses, and triggering a pull timer when everyone is confirmed ready.

---

## 🔧 Features

- `/rcpt` triggers a **ready check**.
  - When all players are ready, it automatically starts a **pull timer**.
  - If not all players are ready, it will retry up to a configured number of times.
  - Players can **cancel the pull timer** by typing configured keywords in party or raid chat (e.g. "stop", "wait").

- Customize behaviors with easy slash commands.

---

## 💬 Slash Command Reference

| Command                         | Description |
|----------------------------------|-------------|
| `/rcpt`                          | Starts the ready check → pull timer sequence |
| `/rcpt help`                     | Prints current configuration and usage info |
| `/rcpt set <key> <value>`       | Sets config value (`pullDuration`, `retryTimeout`, `maxRetries`) |
| `/rcpt addkeyword <word>`       | Adds a cancel keyword (up to 10 total) |
| `/rcpt reset`                   | Resets configuration to defaults |
| `/rcpt quiet`                   | Toggles the debugging text on/off |

---

## ⚙️ Configurable Options

| Config Key     | Description                             | Default |
|----------------|-----------------------------------------|---------|
| `pullDuration` | Seconds for pull countdown              | `10`    |
| `retryTimeout` | Seconds to wait before retrying ready   | `15`    |
| `maxRetries`   | Max retries if players aren't ready     | `2`     |
| `cancelKeywords` | Chat triggers to cancel pull timer    | `stop`, `wait`, `hold` |

To update a value:

`/rcpt set pullDuration 8`

`/rcpt addkeyword abort`

---

## 🔄 Resetting Config

To revert to default settings:

`/rcpt reset`

This will clear saved variables and reload your UI.

---

## 📦 Installation

1. Download the latest from [Wago](https://addons.wago.io/developers/projects/rcpt-addon) or [GitHub Releases](https://github.com/spencerneutron/RCPT-Addon/releases).
2. Extract and place the `RCPT/` folder into your WoW AddOns directory.

---

## 🧪 Notes

- Requires leader or assistant permissions in group to run `/readycheck` and `/pull` equivalents.
- Compatible with Blizzard’s built-in countdown system (no DBM or BigWigs required).
