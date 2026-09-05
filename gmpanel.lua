--[[
    GMPanel - Ashita v4 addon
    ImGui control panel for issuing existing LandSandBoat GM commands.

    The addon does not implement any GM functionality. It builds a command string from the
    selected command plus the shared argument field and queues it through the Ashita chat
    manager, exactly as if the user had typed it in the chat box. The server validates arguments.
]]--

addon.name    = 'gmpanel';
addon.author  = 'Cas.G';
addon.version = '1.0.0';
addon.desc    = 'ImGui panel for issuing LandSandBoat GM commands.';
addon.link    = '';

require('common');
local chat  = require('chat');
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
-- Helpers
-- ---------------------------------------------------------------------------

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

local function queue_selected()
    local command = state.selected;
    if (command == nil) then
        state.status = 'No command selected.';
        return;
    end

    local line = build_command_string(command, state.arg[1]);
    AshitaCore:GetChatManager():QueueCommand(1, line);
    state.last_command = line;
    state.confirm = false;
    state.status = 'Queued: ' .. line;
    print(chat.header(addon.name):append(chat.message('Queued: ' .. line)));
end

-- Execute request from the button or Enter key. Dangerous commands need a second explicit click.
local function request_execute()
    local command = state.selected;
    if (command == nil) then
        state.status = 'No command selected.';
        return;
    end
    if (command.dangerous and not state.confirm) then
        state.confirm = true;
        state.status = 'Dangerous command. Click Confirm to run it, or Cancel.';
        return;
    end
    queue_selected();
end

local function set_argument(value)
    state.arg[1] = tostring(value or '');
    state.confirm = false;
    state.status = 'Argument set to: ' .. state.arg[1];
end

local function copy_to_clipboard(text)
    imgui.SetClipboardText(tostring(text or ''));
    state.status = 'Copied to clipboard.';
end

-- ---------------------------------------------------------------------------
-- UI: pieces
-- ---------------------------------------------------------------------------

local function draw_search_bar()
    imgui.Text('Search');
    imgui.SameLine();
    imgui.SetNextItemWidth(-140);
    imgui.InputText('##gmpanel_search', state.search, 256);
    imgui.SameLine();
    if (imgui.Button('Clear##search', { 60, 0 })) then
        state.search[1] = '';
    end
    imgui.SameLine();
    imgui.TextColored(COLOR_MUTED, '/gm');
end

local function draw_category_list(width, height)
    imgui.BeginChild('##gmpanel_categories', { width, height }, true);
    imgui.TextColored(COLOR_HEADER, 'Categories');
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
    imgui.BeginChild('##gmpanel_commands', { width, height }, true);
    local searching = (trim(state.search[1]) ~= '');
    local list = visible_commands();

    imgui.TextColored(COLOR_HEADER, string.format('Commands (%d)', #list));
    imgui.Separator();

    if (#list == 0) then
        if (searching) then
            imgui.TextColored(COLOR_MUTED, 'No commands match the search.');
        else
            imgui.TextColored(COLOR_MUTED, 'No commands in this category.');
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
            imgui.SetTooltip(command.desc);
        end
    end
    imgui.EndChild();
end

local function draw_detail(width, height)
    imgui.BeginChild('##gmpanel_detail', { width, height }, true);
    local command = state.selected;

    if (command == nil) then
        imgui.TextColored(COLOR_HEADER, 'Details');
        imgui.Separator();
        imgui.TextWrapped('Select a command from the list.');
        imgui.EndChild();
        return;
    end

    imgui.TextColored(COLOR_HEADER, 'Details');
    if (command.dangerous) then
        imgui.SameLine();
        imgui.TextColored(COLOR_DANGER, '[DANGEROUS]');
    end
    imgui.Separator();

    imgui.Text('Syntax:');
    imgui.SameLine();
    imgui.TextWrapped(command.syntax or '');

    imgui.Text('Description:');
    imgui.TextWrapped((command.desc ~= nil and command.desc ~= '') and command.desc or '(none)');

    imgui.Text('Notes:');
    imgui.TextWrapped((command.notes ~= nil and command.notes ~= '') and command.notes or '(none)');

    imgui.Text('Arguments:');
    imgui.SameLine();
    if (command.args ~= nil and command.args ~= '') then
        imgui.TextWrapped(command.args);
    else
        imgui.TextColored(COLOR_MUTED, 'none');
    end

    imgui.Separator();
    imgui.Text('Argument:');
    imgui.SetNextItemWidth(-1);
    if (imgui.InputText('##gmpanel_arg', state.arg, 512, ImGuiInputTextFlags_EnterReturnsTrue)) then
        request_execute();
    end
    if (imgui.Button('Clear argument', { 120, 0 })) then
        state.arg[1] = '';
        state.confirm = false;
    end

    imgui.Text('Will queue:');
    imgui.SameLine();
    imgui.TextWrapped(build_command_string(command, state.arg[1]));

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
            imgui.TextColored(COLOR_DANGER, 'This command is dangerous. Confirm to run it.');
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
        imgui.TextWrapped(state.status);
    end
    if (state.last_command ~= '') then
        imgui.TextColored(COLOR_OK, 'Last queued: ' .. state.last_command);
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
        imgui.TextWrapped(ref.note);
    end

    imgui.BeginChild('##gmpanel_ref_' .. index, { 0, 0 }, true);

    if (#rows == 0 or ncols == 0) then
        imgui.TextColored(COLOR_MUTED, 'No entries.');
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
                imgui.TextColored(COLOR_HEADER, row.group);
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
                imgui.Text(cells[1] or '');
                for c = 2, ncols do
                    local text = cells[c];
                    if (text ~= nil and text ~= '') then
                        imgui.TextColored(COLOR_MUTED, (columns[c] or '') .. ':');
                        imgui.SameLine();
                        imgui.TextWrapped(text);
                    end
                end
            else
                -- Fixed column offsets: buttons occupy the first BUTTON_SPAN pixels of the row.
                for c = 1, ncols do
                    local text = cells[c];
                    if (text == nil or text == '') then
                        text = '-';
                    end
                    if (c > 1) then
                        imgui.SameLine(offsets[c]);
                    end
                    imgui.Text(text);
                end
            end
        end
    end

    if (shown == 0) then
        imgui.TextColored(COLOR_MUTED, 'No entries match the filter.');
    end

    imgui.EndChild();
end

local function draw_reference_area(height)
    imgui.BeginChild('##gmpanel_reference', { 0, height }, true);
    imgui.TextColored(COLOR_HEADER, 'Reference');
    imgui.SameLine();
    imgui.SetNextItemWidth(220);
    imgui.InputText('##gmpanel_ref_filter', state.ref_filter, 128);
    imgui.SameLine();
    if (imgui.Button('Clear##ref', { 60, 0 })) then
        state.ref_filter[1] = '';
    end
    imgui.SameLine();
    imgui.TextColored(COLOR_MUTED, 'Use = put value in the argument field. Copy = clipboard.');

    local refs = data.references or {};
    if (#refs == 0) then
        imgui.TextColored(COLOR_MUTED, 'No reference data available.');
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
-- UI: window
-- ---------------------------------------------------------------------------
local function draw_window()
    imgui.SetNextWindowSize({ 1000, 720 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('GMPanel##gmpanel_main', state.visible, ImGuiWindowFlags_None)) then
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
    imgui.End();
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
ashita.events.register('command', 'gmpanel_command_cb', function (e)
    local args = e.command:args();
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

ashita.events.register('d3d_present', 'gmpanel_present_cb', function ()
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
    print(chat.header(addon.name):append(chat.message(string.format(
        'Loaded %d commands in %d categories. Use /gm or /gmpanel to toggle the panel.',
        count, category_count()))));
end);

ashita.events.register('unload', 'gmpanel_unload_cb', function ()
    state.visible[1] = false;
end);
