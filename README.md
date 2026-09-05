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

## Bot Control tab

The window has two top-level tabs: **Commands** (the generic browser described above, unchanged) and
**Bot Control**. Nothing in Bot Control is tied to a character name. The buttons are generated every
frame from two sources:

- the **server roster**: the reply to `!botparty roster`, one line of the form
  `VanaBots roster: Bob(WAR,Lv5,party 6,alive) Barb(WHM,Lv5,solo,dead)`, parsed from the chat log
  (`text_in`). The tab requests it when opened (at most every 30 s) and on **Refresh roster**;
- the **client party list**: the other members of your own party, in slot order.

Layout:

| Section     | Content                                                                                   |
|-------------|-------------------------------------------------------------------------------------------|
| All bots    | `All: Free Reign / Offensive / Defensive / Passive` (`!botstance <stance>`), `Stance Status`, `Bots: Own Party` (`!botparty party`), `Bots: Split`, `Add All to Me` (`!botparty joinme all`), `Make Me Leader`, `Party Status`, `Bring All` (`!botlife bring all`), `Refresh roster` |
| Your party  | one row per other party member: a bot gets its roster line and buttons; a non-bot is listed as "(not a bot)" with no buttons |
| Other bots  | one row per roster bot that is not in your party                                          |

Per-bot row (`<name>` is the bot's name in lower case):

| Button  | Queued                          | Confirm |
|---------|---------------------------------|---------|
| Kill    | `!botlife kill <name>`          | yes     |
| Respawn | `!botlife respawn <name>`       | no      |
| Bring   | `!botlife bring <name>`         | no      |
| Free / Off / Def / Pass | `!botstance <name> <stance>` | no |
| Join Me | `!botparty joinme <name>`       | no      |
| Lead    | `!botparty leader <name>`       | no      |

Kill uses the same CONFIRM/Cancel step as other dangerous commands; the CONFIRM/Cancel pair appears under
that bot's row. Action tables are cached by their command text, so an armed confirmation survives the
redraw. Clicking any other button, or Cancel, disarms it.

Bring uses `!botlife bring`, an in-zone move performed by the module. The stock `!bring` forces a rezone
by default; headless characters cannot zone (the server now refuses that safely, but the module command is
the intended path).

`!botparty`, `!botstance` and `!botlife` are the Vana Bots module's operator commands
(`modules/vana_bots/lua/*.lua` on the server); they accept any bot name or `all`, and the server rejects
unknown names. The stance and lifecycle state lives on the map server, not in the addon. Not offered
because no existing GM command covers them: spawning or despawning a bot.

### Stub harness

`gmpanel_harness.lua` (kept with the Vana Bots verification material) loads `gmpanel.lua` under fake
Ashita/ImGui globals with a fake party list (player, one bot, one human) and simulates the roster reply and
button clicks. It checks the roster request and its rate limit, the exact string of every per-bot and group
button, that a human party member gets no buttons, the Kill CONFIRM/Cancel flow, and that every line is a
module command. Run with `luajit gmpanel_harness.lua <folder containing gmpanel.lua and data.lua>`.

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
