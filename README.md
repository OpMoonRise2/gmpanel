# GMPanel (Ashita v4 addon)

GMPanel is an ImGui control panel for issuing existing LandSandBoat GM commands on a private server.
It does not implement GM functionality. It builds a command string from the selected command and the
shared argument field, then queues it through the Ashita chat manager exactly as if you typed it in chat.
The server validates all arguments.

GMPanel never connects to a database, never runs SQL, never sends packets, and has no network code.
The SQL Lookups tab is reference text for an external database tool only.

## Files

| File          | Purpose                                                              |
|---------------|----------------------------------------------------------------------|
| `gmpanel.lua` | Addon logic and ImGui panel                                          |
| `data.lua`    | 167 GM commands in 18 categories, plus 9 reference tables            |
| `README.md`   | This file                                                            |

## Install

1. Copy the folder to `<Ashita>/addons/gmpanel/` so that `gmpanel.lua` and `data.lua` sit in that folder.
2. In game: `/addon load gmpanel`
3. Toggle the panel: `/gm` or `/gmpanel` (also `/gm show`, `/gm hide`).

Your character needs GM privileges on the server for the `!` commands to do anything.

## Panel layout

- **Top**: search field. Case-insensitive; matches command, syntax, description, notes, argument hint
  and category name. A non-empty search looks across all categories.
- **Left**: category list (`All` plus 18 categories with counts).
- **Center**: scrollable command list. Dangerous commands are shown in red. Hover for the description.
- **Right (detail)**: syntax, description, notes, argument hint, the shared **Argument** field, a preview of
  the exact string that will be queued, and the **Execute** button. Enter in the argument field also executes.
- **Bottom (reference)**: tabs for Zones, Jobs, Status Effects, Trusts, Weather, Missions, Skillchains,
  Test Recipes and SQL Lookups, with a filter box. **Use** puts the entry's ID/code into the argument
  field; **Copy** puts the entry on the clipboard.

## Command execution

Construction is generic for every command:

```
selected command : !zone
argument field   : 100
queued           : !zone 100
```

If the argument field is empty only the command is queued. Leading/trailing whitespace is trimmed;
internal spaces are preserved (for example `!send Playername !zone 100`).

## Dangerous commands

`!crash`, `!sleep`, `!exec` and every command in **MODERATION (HIGH PRIV)** are marked dangerous.
They show in red, use a red **Execute (dangerous)** button, and require a second click on
**CONFIRM <command>**. **Cancel**, changing the selected command, using a reference **Use** button or
clearing the argument all disarm the confirmation.

## In-game test sequence

```
/addon load gmpanel          -> chat: "Loaded 167 commands in 18 categories."
/gm                          -> panel opens
select MOVEMENT & POSITIONING -> !pos -> Execute      (harmless; prints your position)
type "zone" in Search        -> !zone <id> appears from any category
Reference > Zones > Use on 243 (RuLude Gardens); select !zone; Execute -> "!zone 243" queued
select UTILITY -> !crash     -> Execute (dangerous) -> confirm prompt shown; click Cancel -> nothing queued
select !sleep <n>            -> Execute (dangerous) -> select another command -> confirmation is reset
/addon reload gmpanel
/addon unload gmpanel
```

## Data notes

`data.lua` was generated from the project workbook. Placeholder zone IDs without a name were omitted.
Three commands had blank descriptions in the workbook (`!changesjob`, `!masterjob`, `!capallskills`) and
carry short descriptions derived from the command name. The workbook itself notes that trust spell IDs are
approximate and mission IDs must be verified against the server scripts.
