--[[
    GMPanel - Ashita v4 addon
    ImGui control panel for issuing existing LandSandBoat GM commands.

    The addon does not implement any GM functionality. It builds a command string from the
    selected command plus the shared argument field and queues it through the Ashita chat
    manager, exactly as if the user had typed it in the chat box. The server validates arguments.
]]--

addon.name    = 'gmpanel';
addon.author  = 'Cas.G';
addon.version = '1.2.0';
addon.desc    = 'ImGui panel for issuing LandSandBoat GM commands.';
addon.link    = '';

-- 'common' and 'chat' live in <Ashita>/addons/libs. They are optional here: the addon only uses
-- string:args() from common and colored headers from chat, and falls back when either is missing.
local has_common = pcall(require, 'common');
local has_chat, chat = pcall(require, 'chat');
if (not has_chat) then
    chat = nil;
end
local imgui = require('imgui');
local data  = require('data');

-- ---------------------------------------------------------------------------
-- State (kept local to the addon)
-- ---------------------------------------------------------------------------
local state = {
    visible       = { false },          -- ImGui window open flag (table so Begin can close it)
    search        = { '' },             -- top search field buffer
    arg           = { '' },             -- shared argument field buffer
    ref_filter    = { '' },             -- reference-area filter buffer
    category      = 0,                  -- 0 = All, otherwise index into data.categories
    selected      = nil,                -- currently selected command table (or nil)
    confirm       = false,              -- dangerous-command confirmation armed for the selected command
    last_command  = '',                 -- last string queued (shown in the panel)
    status        = '',                 -- short status line shown under the Execute button
    pending       = {},                 -- queued command lines still to be sent, one per frame
    roster        = {                   -- bots known to the server (parsed from the '!botparty roster' reply)
        bots      = {},                 -- ordered list of { name, job, level, party, alive }
        by_name   = {},                 -- lowercase name -> entry
        updated   = 0,                  -- os.time() of the last parsed reply (0 = never)
        requested = 0,                  -- os.time() of the last request sent
    },
};

-- Color constants (r, g, b, a).
local COLOR_DANGER   = { 1.00, 0.35, 0.35, 1.00 };
local COLOR_MUTED    = { 0.65, 0.65, 0.65, 1.00 };
local COLOR_OK       = { 0.55, 0.90, 0.55, 1.00 };
local COLOR_HEADER   = { 0.90, 0.80, 0.45, 1.00 };
local COLOR_BTN_DNG  = { 0.60, 0.15, 0.15, 1.00 };
local COLOR_BTN_DNGH = { 0.80, 0.20, 0.20, 1.00 };
local COLOR_BTN_DNGA = { 0.95, 0.25, 0.25, 1.00 };

-- ---------------------------------------------------------------------------
-- Bot Control: actions for whichever bots exist and whoever is in your party.
--
-- Nothing here is tied to a character name. The bot roster comes from the server (the
-- '!botparty roster' reply is parsed from the chat log); party membership comes from the
-- client's own party list. Buttons are generated from both every frame.
--
-- Every action is an ordinary command table (same shape as data.lua entries) with one extra
-- field, 'lines': the exact strings queued, in order. Actions with 'lines' ignore the shared
-- argument field. They run through the same select/request/queue/confirm path as every other
-- command, so dangerous actions get the existing CONFIRM step and nothing else. Action tables
-- are cached by their command text so an armed confirmation survives the next frame.
-- ---------------------------------------------------------------------------
local ROSTER_PREFIX  = 'VanaBots roster:';
local ROSTER_REFRESH = 30; -- seconds between automatic roster requests while the tab is open

local action_cache = {};
local function bot_action(group, label, desc, dangerous, lines)
    local key = table.concat(lines, ' ; ');
    local action = action_cache[key];
    if (action == nil) then
        action = {
            cmd       = lines[1],
            syntax    = label,
            args      = '',
            desc      = desc,
            notes     = 'Bot Control: ' .. group,
            dangerous = dangerous,
            lines     = lines,
            group     = group,
        };
        action_cache[key] = action;
    else
        action.syntax = label;
        action.desc   = desc;
    end
    return action;
end

-- Actions that apply to every bot at once.
local function group_actions()
    return {
        bot_action('Group', 'All: Free Reign', 'Every bot: autonomous play for its current leader/role; a bot leader may pull new prey.', false, { '!botstance free' }),
        bot_action('Group', 'All: Offensive',  'Every bot: assist the leader aggressively and continue onto every mob hostile to the party.', false, { '!botstance offensive' }),
        bot_action('Group', 'All: Defensive',  'Every bot: no neutral pulls; fight mobs already hostile to the party; keep healing.', false, { '!botstance defensive' }),
        bot_action('Group', 'All: Passive',    'Every bot: no offensive actions; healing stays allowed.', false, { '!botstance passive' }),
        bot_action('Group', 'Stance Status',   'Prints the stance of every bot.', false, { '!botstance status' }),
        bot_action('Group', 'Bots: Own Party', 'Every bot leaves its party and they form one party of their own (a tank leads).', false, { '!botparty party' }),
        bot_action('Group', 'Bots: Split',     'Every bot leaves its party; all solo.', false, { '!botparty split' }),
        bot_action('Group', 'Add All to Me',   'Every bot joins your party.', false, { '!botparty joinme all' }),
        bot_action('Group', 'Make Me Leader',  'Makes your character leader of your current party.', false, { '!botparty leader me' }),
        bot_action('Group', 'Party Status',    'Prints party, leader, stance and HP of every bot and of your party.', false, { '!botparty status' }),
        bot_action('Group', 'Bring All',       'Moves every bot to your position (same zone).', false, { '!botlife bring all' }),
    };
end

-- Actions for one bot, by name. The server validates the name against its roster.
local function bot_actions(name)
    local lower = string.lower(name);
    return {
        bot_action(name, 'Kill',    'Sets ' .. name .. '\'s HP to 0; the normal death path follows.', true,  { '!botlife kill ' .. lower }),
        bot_action(name, 'Respawn', 'Resurrects a defeated ' .. name .. ' at its home point now (headless respawn, no Raise offer).', false, { '!botlife respawn ' .. lower }),
        bot_action(name, 'Bring',   'Moves ' .. name .. ' to your position (same zone).', false, { '!botlife bring ' .. lower }),
        bot_action(name, 'Free',    name .. ' only: free reign.', false, { '!botstance ' .. lower .. ' free' }),
        bot_action(name, 'Off',     name .. ' only: offensive.',  false, { '!botstance ' .. lower .. ' offensive' }),
        bot_action(name, 'Def',     name .. ' only: defensive.',  false, { '!botstance ' .. lower .. ' defensive' }),
        bot_action(name, 'Pass',    name .. ' only: passive.',    false, { '!botstance ' .. lower .. ' passive' }),
        bot_action(name, 'Join Me', name .. ' joins your party; nobody else moves.', false, { '!botparty joinme ' .. lower }),
        bot_action(name, 'Lead',    'Makes ' .. name .. ' leader of the party.', false, { '!botparty leader ' .. lower }),
    };
end

-- Parses the server's roster line: 'VanaBots roster: Bob(WAR,Lv5,party 6,alive) Barb(WHM,Lv5,solo,dead)'.
-- Returns true when the message was a roster line.
local function parse_roster(msg)
    local start = string.find(tostring(msg or ''), ROSTER_PREFIX, 1, true);
    if (start == nil) then
        return false;
    end
    local bots, by_name = {}, {};
    for name, info in string.gmatch(string.sub(msg, start + #ROSTER_PREFIX), '(%a+)%(([^)]*)%)') do
        local job, level, party, alive = string.match(info, '^(%w+),Lv(%d+),([^,]*),(%a+)$');
        local entry = { name = name, job = job or '?', level = tonumber(level) or 0, party = party or '?', alive = (alive == 'alive') };
        table.insert(bots, entry);
        by_name[string.lower(name)] = entry;
    end
    state.roster.bots    = bots;
    state.roster.by_name = by_name;
    state.roster.updated = os.time();
    return true;
end

-- Names of the other members of the player's own party, in slot order. Slot 0 is the player.
-- Degrades to an empty list when the memory manager is unavailable.
local function party_members()
    local out = {};
    local ok, party = pcall(function () return AshitaCore:GetMemoryManager():GetParty(); end);
    if (not ok or party == nil) then
        return out;
    end
    for i = 1, 5 do
        local active_ok, active = pcall(function () return party:GetMemberIsActive(i); end);
        if (active_ok and (active == 1 or active == true)) then
            local name_ok, name = pcall(function () return party:GetMemberName(i); end);
            if (name_ok and name ~= nil and name ~= '') then
                table.insert(out, name);
            end
        end
    end
    return out;
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Prints a line to the chat log, colored through the chat lib when it is available.
local function say(msg)
    if (chat ~= nil) then
        print(chat.header(addon.name):append(chat.message(msg)));
    else
        print('[' .. addon.name .. '] ' .. msg);
    end
end

-- Splits a command line on whitespace (string:args() when common is loaded, otherwise a local split).
local function split_args(line)
    if (has_common and type(line.args) == 'function') then
        return line:args();
    end
    local out = {};
    for word in string.gmatch(tostring(line or ''), '%S+') do
        table.insert(out, word);
    end
    return out;
end

-- Trim leading/trailing whitespace; internal spaces are preserved.
local function trim(str)
    if (str == nil) then
        return '';
    end
    return (tostring(str):gsub('^%s+', ''):gsub('%s+$', ''));
end

-- Case-insensitive plain-text containment test (no pattern magic).
local function contains(haystack, needle)
    if (haystack == nil or haystack == '' or needle == '' ) then
        return false;
    end
    return string.find(string.lower(haystack), needle, 1, true) ~= nil;
end

local function category_count()
    return (data.categories ~= nil) and #data.categories or 0;
end

-- Returns true when the command matches the (already lowercased) search text.
local function command_matches(command, category_name, needle)
    if (needle == '') then
        return true;
    end
    return contains(command.cmd, needle)
        or contains(command.syntax, needle)
        or contains(command.desc, needle)
        or contains(command.notes, needle)
        or contains(command.args, needle)
        or contains(category_name, needle);
end

-- Builds the list of { command, category_name } entries to display.
local function visible_commands()
    local list = {};
    local needle = string.lower(trim(state.search[1]));
    local count = category_count();

    if (count == 0) then
        return list;
    end

    -- A non-empty search looks across every category; otherwise honor the category selection.
    local first, last = 1, count;
    if (needle == '' and state.category > 0 and state.category <= count) then
        first, last = state.category, state.category;
    end

    for i = first, last do
        local category = data.categories[i];
        local commands = category.commands or {};
        for _, command in ipairs(commands) do
            if (command_matches(command, category.name, needle)) then
                table.insert(list, { command = command, category = category.name });
            end
        end
    end
    return list;
end

local function select_command(command)
    if (state.selected ~= command) then
        state.selected = command;
        state.confirm  = false;   -- changing selection always disarms dangerous confirmation
        state.status   = '';
    end
end

-- Generic command construction: '<cmd>' or '<cmd> <trimmed argument text>'.
local function build_command_string(command, argtext)
    local arg = trim(argtext);
    if (arg == '') then
        return command.cmd;
    end
    return command.cmd .. ' ' .. arg;
end

-- Sends one command line to the game through the Ashita chat manager.
local function send_line(line)
    AshitaCore:GetChatManager():QueueCommand(1, line);
    say('Queued: ' .. line);
end

-- Sends the first line of a multi-line action now and leaves the rest in state.pending.
-- flush_pending() sends exactly one pending line per rendered frame (d3d_present), so two
-- mode-1 commands are never handed to the chat manager in the same frame.
local function flush_pending()
    if (#state.pending == 0) then
        return;
    end
    local line = table.remove(state.pending, 1);
    send_line(line);
    if (#state.pending == 0) then
        state.status = 'Queued: ' .. state.last_command;
    end
end

local function queue_selected()
    local command = state.selected;
    if (command == nil) then
        state.status = 'No command selected.';
        return;
    end

    -- Fixed-line commands (Bot Control) queue their exact strings and ignore the argument field.
    local lines = command.lines or { build_command_string(command, state.arg[1]) };
    local joined = table.concat(lines, ' ; ');
    state.last_command = joined;
    state.confirm = false;

    -- First line now; any further lines go out one per frame.
    state.pending = {};
    for i, line in ipairs(lines) do
        if (i == 1) then
            send_line(line);
        else
            table.insert(state.pending, line);
        end
    end
    if (#state.pending > 0) then
        state.status = string.format('Queued: %s (%d more line(s) follow on the next frames)', lines[1], #state.pending);
    else
        state.status = 'Queued: ' .. joined;
    end
end

-- Execute request from the button or Enter key. Dangerous commands are only armed here;
-- queue_selected() for a dangerous command is reachable solely through the CONFIRM button.
local function request_execute()
    local command = state.selected;
    if (command == nil) then
        state.status = 'No command selected.';
        return;
    end
    if (command.dangerous) then
        -- Never queue from here. Arm (or keep armed) and stop; only the CONFIRM button queues.
        state.confirm = true;
        state.status = 'Dangerous command. Click CONFIRM to run it, or Cancel.';
        return;
    end
    queue_selected();
end

local function set_argument(value)
    state.arg[1] = tostring(value or '');
    state.confirm = false;
    state.status = 'Argument set to: ' .. state.arg[1];
end

-- Asks the server for its bot roster. Automatic requests are rate limited; a click forces one.
local function request_roster(force)
    local now = os.time();
    if (not force and (now - state.roster.requested) < ROSTER_REFRESH) then
        return;
    end
    state.roster.requested = now;
    send_line('!botparty roster');
end

local function copy_to_clipboard(text)
    imgui.SetClipboardText(tostring(text or ''));
    state.status = 'Copied to clipboard.';
end

-- ---------------------------------------------------------------------------
-- Text output. The Ashita v4 ImGui binding takes the string as-is (it is not printf-style: a
-- literal '%s' is drawn verbatim), so text containing '%' is drawn unchanged. Every dynamic string
-- goes through these helpers so nil values are never passed to ImGui.
-- ---------------------------------------------------------------------------
local function text(str)
    imgui.Text(tostring(str or ''));
end

local function text_wrapped(str)
    imgui.TextWrapped(tostring(str or ''));
end

local function text_colored(color, str)
    imgui.TextColored(color, tostring(str or ''));
end

local function tooltip(str)
    imgui.SetTooltip(tostring(str or ''));
end

-- ---------------------------------------------------------------------------
-- UI: pieces
-- ---------------------------------------------------------------------------

local function draw_search_bar()
    text('Search');
    imgui.SameLine();
    imgui.SetNextItemWidth(-140);
    imgui.InputText('##gmpanel_search', state.search, 256);
    imgui.SameLine();
    if (imgui.Button('Clear##search', { 60, 0 })) then
        state.search[1] = '';
    end
    imgui.SameLine();
    text_colored(COLOR_MUTED, '/gm');
end

local function draw_category_list(width, height)
    imgui.BeginChild('##gmpanel_categories', { width, height }, ImGuiChildFlags_Borders);
    text_colored(COLOR_HEADER, 'Categories');
    imgui.Separator();

    if (imgui.Selectable('All', state.category == 0)) then
        state.category = 0;
    end
    for i = 1, category_count() do
        local category = data.categories[i];
        local label = string.format('%s (%d)##cat%d', category.name, #(category.commands or {}), i);
        if (imgui.Selectable(label, state.category == i)) then
            state.category = i;
        end
    end
    imgui.EndChild();
end

local function draw_command_list(width, height)
    imgui.BeginChild('##gmpanel_commands', { width, height }, ImGuiChildFlags_Borders);
    local searching = (trim(state.search[1]) ~= '');
    local list = visible_commands();

    text_colored(COLOR_HEADER, string.format('Commands (%d)', #list));
    imgui.Separator();

    if (#list == 0) then
        if (searching) then
            text_colored(COLOR_MUTED, 'No commands match the search.');
        else
            text_colored(COLOR_MUTED, 'No commands in this category.');
        end
    end

    for i, entry in ipairs(list) do
        local command = entry.command;
        local label = command.syntax;
        if (searching) then
            label = string.format('%s  [%s]', command.syntax, entry.category);
        end
        label = label .. '##cmd' .. i;

        if (command.dangerous) then
            imgui.PushStyleColor(ImGuiCol_Text, COLOR_DANGER);
        end
        if (imgui.Selectable(label, state.selected == command)) then
            select_command(command);
        end
        if (command.dangerous) then
            imgui.PopStyleColor(1);
        end
        if (imgui.IsItemHovered() and command.desc ~= '') then
            tooltip(command.desc);
        end
    end
    imgui.EndChild();
end

local function draw_detail(width, height)
    imgui.BeginChild('##gmpanel_detail', { width, height }, ImGuiChildFlags_Borders);
    local command = state.selected;

    if (command == nil) then
        text_colored(COLOR_HEADER, 'Details');
        imgui.Separator();
        text_wrapped('Select a command from the list.');
        imgui.EndChild();
        return;
    end

    text_colored(COLOR_HEADER, 'Details');
    if (command.dangerous) then
        imgui.SameLine();
        text_colored(COLOR_DANGER, '[DANGEROUS]');
    end
    imgui.Separator();

    text('Syntax:');
    imgui.SameLine();
    text_wrapped(command.syntax or '');

    text('Description:');
    text_wrapped((command.desc ~= nil and command.desc ~= '') and command.desc or '(none)');

    text('Notes:');
    text_wrapped((command.notes ~= nil and command.notes ~= '') and command.notes or '(none)');

    text('Arguments:');
    imgui.SameLine();
    if (command.args ~= nil and command.args ~= '') then
        text_wrapped(command.args);
    else
        text_colored(COLOR_MUTED, 'none');
    end

    imgui.Separator();
    text('Argument:');
    imgui.SetNextItemWidth(-1);
    if (imgui.InputText('##gmpanel_arg', state.arg, 512, ImGuiInputTextFlags_EnterReturnsTrue)) then
        request_execute();
    end
    if (imgui.Button('Clear argument', { 120, 0 })) then
        state.arg[1] = '';
        state.confirm = false;
    end

    text('Will queue:');
    imgui.SameLine();
    if (command.lines ~= nil) then
        text_wrapped(table.concat(command.lines, ' ; '));
    else
        text_wrapped(build_command_string(command, state.arg[1]));
    end

    imgui.Separator();

    if (command.dangerous) then
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BTN_DNG);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BTN_DNGH);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BTN_DNGA);
        if (state.confirm) then
            if (imgui.Button('CONFIRM ' .. command.cmd, { 200, 0 })) then
                queue_selected();
            end
            imgui.SameLine();
            if (imgui.Button('Cancel', { 80, 0 })) then
                state.confirm = false;
                state.status = 'Cancelled.';
            end
            text_colored(COLOR_DANGER, 'This command is dangerous. Confirm to run it.');
        else
            if (imgui.Button('Execute (dangerous)', { 200, 0 })) then
                request_execute();
            end
        end
        imgui.PopStyleColor(3);
    else
        if (imgui.Button('Execute', { 200, 0 })) then
            request_execute();
        end
    end

    if (state.status ~= '') then
        text_wrapped(state.status);
    end
    if (state.last_command ~= '') then
        text_colored(COLOR_OK, 'Last queued: ' .. state.last_command);
    end

    imgui.EndChild();
end

-- Draws one reference table (rows grouped by the workbook section headers).
local function draw_reference(ref, index)
    local rows = ref.rows or {};
    local columns = ref.columns or {};
    local ncols = #columns;
    local needle = string.lower(trim(state.ref_filter[1]));

    if (ref.note ~= nil and ref.note ~= '') then
        text_wrapped(ref.note);
    end

    imgui.BeginChild('##gmpanel_ref_' .. index, { 0, 0 }, ImGuiChildFlags_Borders);

    if (#rows == 0 or ncols == 0) then
        text_colored(COLOR_MUTED, 'No entries.');
        imgui.EndChild();
        return;
    end

    local widths = ref.widths or {};
    local BUTTON_SPAN = 100;   -- Use + Copy buttons and spacing
    local offsets = {};
    local x = BUTTON_SPAN;
    for c = 1, ncols do
        offsets[c] = x;
        x = x + (widths[c] or 120);
    end
    local shown = 0;
    local last_group = nil;
    local multiline = (ref.name == 'Test Recipes' or ref.name == 'SQL Lookups');

    for r, row in ipairs(rows) do
        local cells = row.cells or {};
        local match = (needle == '');
        if (not match) then
            for c = 1, ncols do
                if (contains(cells[c], needle)) then
                    match = true;
                    break;
                end
            end
            if (not match and contains(row.group, needle)) then
                match = true;
            end
        end

        if (match) then
            shown = shown + 1;
            if (row.group ~= last_group and row.group ~= nil and row.group ~= '') then
                imgui.Separator();
                text_colored(COLOR_HEADER, row.group);
                last_group = row.group;
            end

            -- Action buttons first so the row stays usable even when text is long.
            local usevalue = (ref.use ~= nil) and cells[ref.use] or nil;
            if (usevalue ~= nil and usevalue ~= '') then
                if (imgui.Button('Use##use' .. index .. '_' .. r, { 40, 0 })) then
                    set_argument(usevalue);
                end
                imgui.SameLine();
            end
            local copyvalue = cells[ref.copy or ref.use or 1] or '';
            if (imgui.Button('Copy##copy' .. index .. '_' .. r, { 45, 0 })) then
                copy_to_clipboard(copyvalue);
            end
            imgui.SameLine();

            if (multiline) then
                -- Multi-line entries: label on the button line, body wrapped underneath.
                text(cells[1] or '');
                for c = 2, ncols do
                    local cell = cells[c];
                    if (cell ~= nil and cell ~= '') then
                        text_colored(COLOR_MUTED, (columns[c] or '') .. ':');
                        imgui.SameLine();
                        text_wrapped(cell);
                    end
                end
            else
                -- Fixed column offsets: buttons occupy the first BUTTON_SPAN pixels of the row.
                for c = 1, ncols do
                    local cell = cells[c];
                    if (cell == nil or cell == '') then
                        cell = '-';
                    end
                    if (c > 1) then
                        imgui.SameLine(offsets[c]);
                    end
                    text(cell);
                end
            end
        end
    end

    if (shown == 0) then
        text_colored(COLOR_MUTED, 'No entries match the filter.');
    end

    imgui.EndChild();
end

local function draw_reference_area(height)
    imgui.BeginChild('##gmpanel_reference', { 0, height }, ImGuiChildFlags_Borders);
    text_colored(COLOR_HEADER, 'Reference');
    imgui.SameLine();
    imgui.SetNextItemWidth(220);
    imgui.InputText('##gmpanel_ref_filter', state.ref_filter, 128);
    imgui.SameLine();
    if (imgui.Button('Clear##ref', { 60, 0 })) then
        state.ref_filter[1] = '';
    end
    imgui.SameLine();
    text_colored(COLOR_MUTED, 'Use = put value in the argument field. Copy = clipboard.');

    local refs = data.references or {};
    if (#refs == 0) then
        text_colored(COLOR_MUTED, 'No reference data available.');
        imgui.EndChild();
        return;
    end

    if (imgui.BeginTabBar('##gmpanel_ref_tabs', ImGuiTabBarFlags_None)) then
        for i, ref in ipairs(refs) do
            if (imgui.BeginTabItem((ref.name or ('Ref ' .. i)) .. '##reftab' .. i)) then
                draw_reference(ref, i);
                imgui.EndTabItem();
            end
        end
        imgui.EndTabBar();
    end
    imgui.EndChild();
end

-- ---------------------------------------------------------------------------
-- UI: Bot Control tab
-- ---------------------------------------------------------------------------

-- Confirmation pair for an armed dangerous action, drawn on its own line.
local function draw_confirm_bar(action, id)
    imgui.Indent(20);
    imgui.PushStyleColor(ImGuiCol_Button, COLOR_BTN_DNG);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BTN_DNGH);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BTN_DNGA);
    if (imgui.Button('CONFIRM ' .. action.syntax .. id, { 170, 0 })) then
        queue_selected();
    end
    imgui.PopStyleColor(3);
    imgui.SameLine();
    if (imgui.Button('Cancel' .. id, { 80, 0 })) then
        state.confirm = false;
        state.status = 'Cancelled.';
    end
    imgui.SameLine();
    text_colored(COLOR_DANGER, 'Dangerous: ' .. table.concat(action.lines, ' ; '));
    imgui.Unindent(20);
end

-- One compact button. Dangerous actions arm the shared confirmation exactly like the generic
-- Execute button; the CONFIRM/Cancel pair is drawn by the caller under the row.
local function draw_action_button(action, id, width)
    if (action.dangerous) then
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BTN_DNG);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BTN_DNGH);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BTN_DNGA);
    end
    if (imgui.Button(action.syntax .. id, { width or 70, 0 })) then
        select_command(action);
        request_execute();
    end
    if (action.dangerous) then
        imgui.PopStyleColor(3);
    end
    if (imgui.IsItemHovered()) then
        tooltip(action.desc .. '\nQueues: ' .. table.concat(action.lines, ' ; '));
    end
end

-- A row of buttons; returns the armed action of this row, if any.
local function draw_action_row(actions, id_prefix, width)
    local armed = nil;
    for i, action in ipairs(actions) do
        if (i > 1) then
            imgui.SameLine();
        end
        draw_action_button(action, id_prefix .. i, width);
        if (state.selected == action and state.confirm) then
            armed = action;
        end
    end
    if (armed ~= nil) then
        draw_confirm_bar(armed, id_prefix .. 'confirm');
    end
end

-- One bot: its roster line (when known) and its action row.
local function draw_bot_row(name, entry, id_prefix)
    if (entry ~= nil) then
        text_colored(entry.alive and COLOR_OK or COLOR_DANGER, string.format('%s  %s Lv%d  %s  %s', entry.name, entry.job, entry.level, entry.party, entry.alive and 'alive' or 'dead'));
    else
        text_colored(COLOR_HEADER, name);
    end
    draw_action_row(bot_actions(name), id_prefix, 62);
end

local function draw_bot_control()
    imgui.BeginChild('##gmpanel_botcontrol', { 0, 0 }, ImGuiChildFlags_Borders);
    text_colored(COLOR_HEADER, 'Bot Control');
    imgui.SameLine();
    text_colored(COLOR_MUTED, 'Buttons come from the server roster and your party list. Red actions ask for confirmation first.');
    imgui.Separator();

    -- Keep the roster current while the tab is open (rate limited); the reply is parsed from the chat log.
    request_roster(false);

    -- Group actions.
    imgui.Spacing();
    text_colored(COLOR_HEADER, 'All bots');
    imgui.SameLine();
    if (imgui.Button('Refresh roster##roster_refresh', { 110, 0 })) then
        request_roster(true);
    end
    imgui.SameLine();
    if (state.roster.updated == 0) then
        text_colored(COLOR_MUTED, 'roster: waiting for the server reply (!botparty roster)');
    else
        text_colored(COLOR_MUTED, string.format('roster: %d bot(s), %ds ago', #state.roster.bots, os.time() - state.roster.updated));
    end
    imgui.Separator();
    draw_action_row(group_actions(), '##grp', 105);

    -- Your party: every other member, with actions when the server knows it as a bot.
    imgui.Spacing();
    text_colored(COLOR_HEADER, 'Your party');
    imgui.Separator();
    local members = party_members();
    local in_party = {};
    if (#members == 0) then
        text_colored(COLOR_MUTED, 'No other party members.');
    end
    for i, name in ipairs(members) do
        in_party[string.lower(name)] = true;
        local entry = state.roster.by_name[string.lower(name)];
        if (entry ~= nil) then
            draw_bot_row(name, entry, '##pm' .. i);
        else
            text_colored(COLOR_MUTED, name .. '  (not a bot)');
        end
    end

    -- Bots that are not in your party.
    imgui.Spacing();
    text_colored(COLOR_HEADER, 'Other bots');
    imgui.Separator();
    local others = 0;
    for i, entry in ipairs(state.roster.bots) do
        if (not in_party[string.lower(entry.name)]) then
            others = others + 1;
            draw_bot_row(entry.name, entry, '##ob' .. i);
        end
    end
    if (others == 0) then
        text_colored(COLOR_MUTED, (#state.roster.bots == 0) and 'No roster yet.' or 'Every known bot is in your party.');
    end

    imgui.Spacing();
    imgui.Separator();
    text_colored(COLOR_MUTED, 'Not available (no existing GM command): spawn/despawn a bot. Kill/respawn/bring/stance use the Vana Bots module commands.');
    if (state.status ~= '') then
        text_wrapped(state.status);
    end
    if (state.last_command ~= '') then
        text_colored(COLOR_OK, 'Last queued: ' .. state.last_command);
    end
    imgui.EndChild();
end

-- ---------------------------------------------------------------------------
-- UI: window
-- ---------------------------------------------------------------------------
-- The original generic layout, unchanged: search, categories, command list, detail, reference.
local function draw_commands_tab()
    draw_search_bar();
    imgui.Separator();

    local avail_w, avail_h = imgui.GetContentRegionAvail();
    local top_h = math.max(200, math.floor(avail_h * 0.55));
    local ref_h = math.max(120, avail_h - top_h - 8);
    local cat_w = 230;
    local detail_w = 330;
    local list_w = math.max(150, avail_w - cat_w - detail_w - 16);

    draw_category_list(cat_w, top_h);
    imgui.SameLine();
    draw_command_list(list_w, top_h);
    imgui.SameLine();
    draw_detail(detail_w, top_h);

    draw_reference_area(ref_h);
end

local function draw_window()
    imgui.SetNextWindowSize({ 1000, 720 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('GMPanel##gmpanel_main', state.visible, ImGuiWindowFlags_None)) then
        if (imgui.BeginTabBar('##gmpanel_top_tabs', ImGuiTabBarFlags_None)) then
            if (imgui.BeginTabItem('Commands##toptab_commands')) then
                draw_commands_tab();
                imgui.EndTabItem();
            end
            if (imgui.BeginTabItem('Bot Control##toptab_bots')) then
                draw_bot_control();
                imgui.EndTabItem();
            end
            imgui.EndTabBar();
        end
    end
    imgui.End();
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
ashita.events.register('command', 'gmpanel_command_cb', function (e)
    local args = split_args(e.command);
    if (#args == 0) then
        return;
    end
    local name = string.lower(args[1]);
    if (name ~= '/gm' and name ~= '/gmpanel') then
        return;
    end
    e.blocked = true;

    local sub = (args[2] ~= nil) and string.lower(args[2]) or 'toggle';
    if (sub == 'show' or sub == 'on') then
        state.visible[1] = true;
    elseif (sub == 'hide' or sub == 'off') then
        state.visible[1] = false;
    else
        state.visible[1] = not state.visible[1];
    end
end);

-- The server answers '!botparty roster' in the chat log; that line is the bot roster.
ashita.events.register('text_in', 'gmpanel_text_in_cb', function (e)
    parse_roster(e.message);
end);

ashita.events.register('d3d_present', 'gmpanel_present_cb', function ()
    -- One pending command line per frame, whether or not the window is shown.
    flush_pending();
    if (not state.visible[1]) then
        return;
    end
    draw_window();
end);

ashita.events.register('load', 'gmpanel_load_cb', function ()
    local count = 0;
    for i = 1, category_count() do
        count = count + #(data.categories[i].commands or {});
    end
    say(string.format('Loaded %d commands in %d categories. Use /gm or /gmpanel to toggle the panel.',
        count, category_count()));
end);

ashita.events.register('unload', 'gmpanel_unload_cb', function ()
    state.visible[1] = false;
    state.pending = {};
end);
