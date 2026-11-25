# RCPT Quick Start

## Main features

- Ready check and pull timer: manage ready checks and start pull timers from a compact overlay using
    ```
    /rcpt
    ```
- TalentCheck overlay: shows your specialization, loadout name, and overall equipment durability during ready checks.
  - Optionally, automatically post a message in your party chat with the loadout name for more visibility

## More details

#### TalentCheck
- Start the ready check as normal, or receive one as a group member. The RCPT TalentCheck overlay appears and provides Ready and Not Ready controls.
- The TalentCheck overlay also shows your current spec, active loadout name, and a summary of low durability slots.
- Configure options in the options panel: `/rcpt options` (also `config`, `opt`), Options -> AddOns -> RCPT, or the RCPT entry in the addon compartment. Toggle replacing the default ready check and adjust durability settings there.
- Use the Tools buttons in the panel: Test ready check previews the overlay, Preview pull frame (or `/rcpt preview`) demos the pull timer frame, and Reset frame positions puts the pull timer and ready check frames back at their default positions. The Appearance section sets the frame scale and can lock the frames in place.

#### Automated Pull Timers
- When you start a ready check (normally or with /rcpt) you will automatically initiate a pull timer if everyone becomes ready
- If a ready check you started fails, it will automatically retry after a configurable number of seconds up to a configurable number of times before abandoning
- Pull timers you start this way can be automatically cancelled by a party member saying a keyword, also configurable as a comma delimited list 

#### Rapid Mode
- Built for progression retries: the raid chains pulls with minimal downtime, and a new countdown starts automatically after combat finishes
- Runs a longer rolling countdown, sends the ready check automatically at the right point, and cancels before the pull if the raid is not ready
- Supports defer, restart, skip-forward, and stop controls (`/rcpt rapid skip`, `defer`, `restart`, `stop`)
- Start or stop a session with `/rcpt rapid`, the Rapid Mode session button in the options panel, or a right-click on RCPT in the addon compartment (leader or assistant only)
 
## Installation

- Place the `RCPT` folder inside your World of Warcraft AddOns directory, alongside the `RCPT_TalentCheck` and `RCPT_PullTimers` folders

## Support

- For help, first check the options panel (`/rcpt options`) or consult the project page where you downloaded the addon for a detailed readme.
- Submit an [issue](https://github.com/spencerneutron/RCPT-Addon/issues/new) on GitHub