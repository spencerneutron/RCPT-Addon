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
- Configure options in the game menu at Interface -> AddOns -> RCPT. Toggle replacing the default ready check and adjust durability settings there.
- Use the in-panel Test Ready Overlay button in Interface -> AddOns -> RCPT to preview the overlay.

#### Automated Pull Timers
- When you start a ready check (normally or with /rcpt) you will automatically initiate a pull timer if everyone becomes ready
- If a ready check you started fails, it will automatically retry after a configurable number of seconds up to a configurable number of times before abandoning
- Pull timers you start this way can be automatically cancelled by a party member saying a keyword, also configurable as a comma delimited list 
 
## Installation

- Place the `RCPT` folder inside your World of Warcraft AddOns directory, alongside the `RCPT_TalentCheck` and `RCPT_PullTimers` folders

## Support

- For help, first check the configuration panel at Interface -> AddOns -> RCPT or consult the project page where you downloaded the addon for a detailed readme.
- Submit an [issue](https://github.com/spencerneutron/RCPT-Addon/issues/new) on GitHub