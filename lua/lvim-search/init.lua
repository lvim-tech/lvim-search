-- lvim-search: the entry point and the lifecycle — when the lenses appear, when they refresh, and
-- when they go away.
--
-- NO MAPPINGS. The plugin never touches `n`, `N`, `*`, `#`, `/` or `?`. It learns that a search is
-- highlighted the same way the screen does: `v:hlsearch`, read from a DECORATION PROVIDER's
-- `on_start`, which Neovim calls once per redraw cycle. That is the only seam that sees every way a
-- search can begin or end — `:nohlsearch`, `<Esc>` on an incsearch, a plugin's own jump, a `:s` —
-- and it costs one integer read per redraw. Wrapping the user's keys instead would mean owning
-- their behaviour forever: counts, registers, operator-pending, folds, and every plugin that also
-- wanted `n`.
--
-- THE PROVIDER IS A SENSOR, NOT A RENDERER. Its callback runs mid-redraw, where setting non-
-- ephemeral extmarks is not allowed; so it only notices the transition and hands the actual paint to
-- `vim.schedule`. Everything the plugin draws is drawn from ordinary main-loop code.
--
-- WHY BOTH A PROVIDER AND AUTOCMDS. The provider answers "is a search highlighted"; the autocmds
-- answer "has anything changed that the lenses depend on" — the cursor (which one is nearest), the
-- view (which are on screen), the text (where they are), the case options (what counts as a match)
-- and the cmdline (a NEW pattern while the old one was still highlighted — the one case the cursor
-- may not move for).
--
-- CALM_DOWN GOES THROUGH `vim.schedule`. Neovim saves and restores the search-highlight state around
-- autocommand execution, so `v:hlsearch = 0` written inside a `CursorMoved` callback is discarded —
-- measured here, not assumed. Scheduling it runs the assignment on the main loop, after the restore,
-- which is where the command was always meant to be executed from.
--
---@module "lvim-search"

local config = require("lvim-search.config")
local highlights = require("lvim-search.highlights")
local lens = require("lvim-search.lens")
local matches = require("lvim-search.matches")
local nearest = require("lvim-search.nearest")
local merge = require("lvim-utils.utils").merge

local api = vim.api
local fn = vim.fn
local uv = vim.uv

local M = {}

---@class LvimSearchStatus
---@field pattern string    the pattern being counted
---@field current integer   1-based index of the nearest match
---@field total integer     how many matches there are
---@field capped boolean    the scan stopped at `scan.max_matches`
---@field on_match boolean  the cursor is inside the nearest match
---@field forward boolean   `n` moves towards higher indices

---@type "IDLE"|"ACTIVE"  ACTIVE means a search is highlighted and lenses are ours to keep current
M.state = "IDLE"

---@type table<integer, true>  buffers currently carrying our extmarks, so they can all be cleaned
local painted = {}
---@type table<integer, string>  window id → a description of what is drawn in it. A scroll repaints
--- every window of the tab page, but only the one that moved has anything new to show; re-rendering
--- the others churns their extmarks for no reason at all.
local drawn_key = {}

---@type LvimSearchStatus?  what was last published
local current_status = nil

---@type uv.uv_timer_t?  the throttle's trailing-edge timer
local timer = nil
---@type integer  uv.now() of the last paint
local last_paint = 0
---@type boolean  a trailing paint is already queued
local queued = false
---@type string?  the pattern that queued paint should count instead of `@/` (an incsearch preview)
local queued_preview = nil
---@type { lnum: integer, col: integer, forward: boolean }?  where the cursor was when the search
--- command line was opened, and which way it will travel. Captured there because 'incsearch' moves
--- the cursor to the previewed match, so by the first keystroke the original position is gone.
local preview_origin = nil
---@type integer  the shortest pattern still worth previewing in this command line. Raised when a
--- scan overruns its budget, reset when a new command line opens.
local preview_floor = 0
---@type boolean  setup() has run
local ready = false

---@type integer  the decoration provider's namespace — it draws nothing, it only listens
local sensor_ns = api.nvim_create_namespace("LvimSearchSensor")

--- Should this window/buffer pair be decorated at all?
---@param win integer
---@param buf integer
---@return boolean
local function eligible(win, buf)
    if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(buf) then
        return false
    end
    if vim.tbl_contains(config.ignore.buftype, vim.bo[buf].buftype) then
        return false
    end
    if vim.tbl_contains(config.ignore.filetype, vim.bo[buf].filetype) then
        return false
    end
    return true
end

--- Announce the counter, so a statusline can show `3/10` without scanning anything itself.
--- Fired only when the value actually changed — a `User` autocmd on every cursor move would be a
--- redraw storm for anyone listening.
---@param status LvimSearchStatus?
---@return nil
local function publish(status)
    local same = (current_status == nil and status == nil)
        or (
            current_status ~= nil
            and status ~= nil
            and current_status.current == status.current
            and current_status.total == status.total
            and current_status.pattern == status.pattern
            and current_status.on_match == status.on_match
        )
    current_status = status
    if same or not config.counter.publish then
        return
    end
    api.nvim_exec_autocmds("User", {
        pattern = "LvimSearchStatus",
        data = status or {},
        modeline = false,
    })
end

--- Drop every lens the plugin has anywhere, and forget the counter.
---@return nil
local function wipe()
    for buf in pairs(painted) do
        lens.clear(buf)
    end
    painted = {}
    drawn_key = {}
    -- The emphasis lives on the window's match list, not in the buffer, so it is cleared per window
    -- — every window, since the plugin may have painted in one the user has since left.
    lens.clear_emphasis()
    publish(nil)
end

--- The windows to decorate: every eligible one in the tab page, or just the current.
---
--- Deduplicated by BUFFER, current window first. Lens extmarks live in the buffer, so one buffer
--- shown in two windows cannot carry two different sets of counters — and the honest tie-break is
--- the window the reader is actually in, rather than whichever happened to be painted last.
---@return table[]  { win, buf } pairs
local function targets()
    local current = api.nvim_get_current_win()
    local out, seen = {}, {}

    local candidates = { current }
    if config.windows ~= "current" then
        for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
            candidates[#candidates + 1] = win
        end
    end

    for _, win in ipairs(candidates) do
        if api.nvim_win_is_valid(win) then
            local buf = api.nvim_win_get_buf(win)
            if not seen[buf] and eligible(win, buf) then
                seen[buf] = true
                out[#out + 1] = { win = win, buf = buf }
            end
        end
    end
    return out
end

--- Draw the current state, now. The single place that decides what is on screen.
---@param preview string?  a pattern being TYPED, to count instead of the committed one. Given, it
---   overrides both the search register and the ACTIVE requirement — nothing is committed yet.
---@return nil
local function paint(preview)
    queued = false
    last_paint = uv.now()

    if not config.enabled or (preview == nil and M.state ~= "ACTIVE") then
        wipe()
        return
    end

    local pattern = preview or fn.getreg("/")
    if type(pattern) ~= "string" or pattern == "" then
        wipe()
        return
    end

    local windows = targets()
    if #windows == 0 then
        wipe()
        return
    end

    -- Whatever is no longer on screen keeps none of our marks.
    local live = {}
    for _, t in ipairs(windows) do
        live[t.buf] = true
    end
    for other in pairs(painted) do
        if not live[other] then
            lens.clear(other)
            painted[other] = nil
        end
    end
    for win in pairs(drawn_key) do
        if not api.nvim_win_is_valid(win) then
            drawn_key[win] = nil
        end
    end

    local current = api.nvim_get_current_win()
    local reported = nil

    for _, t in ipairs(windows) do
        local started = preview ~= nil and uv.hrtime() or nil
        local result = matches.get(t.buf, pattern)
        if started then
            -- A pattern whose scan overruns the budget is too broad to preview. It is not retried at
            -- this length: the next keystroke makes it more selective, and therefore cheaper.
            local ms = (uv.hrtime() - started) / 1e6
            if ms > math.max(1, config.preview.budget) then
                preview_floor = #pattern + 1
            end
        end

        if not result or result.total == 0 then
            lens.clear(t.buf)
            lens.clear_emphasis(t.win)
            painted[t.buf] = nil
            drawn_key[t.win] = nil
        else
            local near
            if preview ~= nil and t.win == current then
                -- Counted from where the reader WAS, not from where 'incsearch' has parked the
                -- cursor, and shaped as the position <CR> will leave them in — so committing
                -- changes no number. Only for the window the search was typed in; the others have
                -- their own cursors and no destination of their own.
                local pos = api.nvim_win_get_cursor(t.win)
                near = nearest.destination(
                    result.matches,
                    preview_origin or { lnum = pos[1], col = pos[2], forward = true }
                )
            else
                near = nearest.of_cursor(result.matches, t.win)
            end

            -- The cursor has wandered off the match it was on: end the search, as asked. Never while
            -- a pattern is being typed — the cursor has not moved, and there is no search to end
            -- yet, and never for a window the reader is not in.
            if preview == nil and config.calm_down and t.win == current and near ~= nil and not near.on_match then
                M.stop()
                -- Outside the autocmd, where the highlight state is no longer restored around us.
                vim.schedule(function()
                    vim.v.hlsearch = 0
                end)
                return
            end

            local list = result.matches
            -- Above the cap the positions are only partly known, so the per-match lenses would be a
            -- lie; the nearest counter still is not, and `degrade = "count"` keeps just that.
            if result.capped and config.scan.degrade == "off" then
                list = {}
                near = nil
            elseif result.capped and config.scan.degrade == "count" and near ~= nil then
                local only = list[near.index]
                list = only and { only } or {}
                near = only
                        and { index = 1, on_match = near.on_match, forward = near.forward, before = 1, rel = near.rel }
                    or nil
            end

            -- What this window would show, as one string. Everything the render depends on is in
            -- it: the text, the pattern, the slice on screen and which match is named.
            local top, bot = 0, 0
            api.nvim_win_call(t.win, function()
                top, bot = fn.line("w0"), fn.line("w$")
            end)
            local key = ("%d:%s:%d:%d:%d:%d:%s"):format(
                api.nvim_buf_get_changedtick(t.buf),
                pattern,
                top,
                bot,
                near and near.index or 0,
                near and near.before or 0,
                tostring(near ~= nil and near.on_match or false)
            )
            if drawn_key[t.win] ~= key then
                lens.render(t.win, t.buf, list, near)
                drawn_key[t.win] = key
            end
            painted[t.buf] = true

            if t.win == current then
                reported = {
                    pattern = pattern,
                    current = near and near.index or 0,
                    total = result.total,
                    capped = result.capped or false,
                    on_match = near ~= nil and near.on_match or false,
                    -- Not `near.forward or true` — that answers true for a backwards search.
                    forward = near == nil or near.forward,
                    -- A statusline can tell a settled count from one that changes with a keystroke.
                    preview = preview ~= nil,
                }
            end
        end
    end

    -- The counter describes where the READER is, so it comes from the current window alone.
    publish(reported)

    -- Neovim's own redraw for the 'incsearch' preview has already happened by the time this runs,
    -- so without asking for another the lenses would not appear until <CR>. This is what `:redraw`
    -- is documented for — updating the screen while the command line is open.
    if preview ~= nil and config.preview.redraw then
        vim.cmd("redraw")
    end
end

--- Paint, throttled: the FIRST event of a burst is honoured immediately (a cursor move should feel
--- instant) and the storm behind it collapses into one trailing paint.
---@param immediate boolean?  bypass the throttle entirely
---@param preview string?     a pattern being typed; see `paint`
---@return nil
local function schedule(immediate, preview)
    -- The trailing paint must use the LATEST pattern, not the one that queued the timer.
    queued_preview = preview
    if preview == nil and M.state ~= "ACTIVE" and not immediate then
        return
    end
    if immediate then
        paint(preview)
        return
    end
    local wait = config.throttle - (uv.now() - last_paint)
    if wait <= 0 then
        paint(preview)
        return
    end
    if queued or not timer then
        return
    end
    queued = true
    timer:start(
        wait,
        0,
        vim.schedule_wrap(function()
            paint(queued_preview)
        end)
    )
end

--- Begin keeping the lenses current.
---@return nil
function M.start()
    if not config.enabled then
        return
    end
    M.state = "ACTIVE"
    schedule(true)
end

--- Stop, and leave nothing behind.
---@return nil
function M.stop()
    M.state = "IDLE"
    if timer then
        timer:stop()
    end
    queued = false
    queued_preview = nil
    preview_floor = 0
    wipe()
end

--- Flip between the two.
---@return nil
function M.toggle()
    if M.state == "ACTIVE" then
        M.stop()
    else
        M.start()
    end
end

--- Repaint now, whatever the throttle thinks.
---@return nil
function M.refresh()
    schedule(true)
end

--- Count `pattern` as if it were being typed: draw its lenses without touching the search register
--- and without committing to anything. This is what the 'incsearch' preview runs on, and it is
--- public because "how many would THIS match" is a question worth being able to ask — a picker
--- previewing a pattern wants the same answer.
---@param pattern string  the pattern as typed; too short a one draws nothing
---@return boolean drawing  whether anything is on screen for it
function M.preview(pattern)
    if not config.enabled or type(pattern) ~= "string" then
        return false
    end
    if #pattern < math.max(1, config.preview.min_chars, preview_floor) then
        -- Too short to mean anything yet: one character matches most of a large file and the answer
        -- changes completely with the next keystroke. The redraw is asked for only when there is
        -- something to take off the screen — otherwise this costs a full redraw to change nothing.
        local had = next(painted) ~= nil
        wipe()
        if had and config.preview.redraw then
            vim.cmd("redraw")
        end
        return false
    end
    -- Painted at once rather than through the throttle: a deferred paint is scheduled onto the main
    -- loop, and the main loop does not run while the command line is blocked waiting for the next
    -- keystroke — measured. A throttled preview would simply never land. The budget above is what
    -- keeps the synchronous scan honest.
    schedule(true, pattern)
    return true
end

--- The counter, for a statusline that would rather poll than listen.
---@return LvimSearchStatus?
function M.status()
    return current_status
end

--- Send every match of the current search to the quickfix list (or to `config.on_list`).
---@param opts { scope: "buffer"|"all"|"args"|nil, buf: integer? }?
---@return integer count
function M.export(opts)
    return require("lvim-search.qf").export(opts)
end

--- Wire the sensor and the refresh triggers.
---@return nil
local function attach()
    local group = api.nvim_create_augroup("LvimSearch", { clear = true })

    -- The sensor. `on_start` runs once per redraw cycle, before anything is drawn; it must be cheap
    -- and it must not draw. Reading one v: variable and comparing it to our state is the whole body.
    api.nvim_set_decoration_provider(sensor_ns, {
        on_start = function()
            -- While a command line is open, what the screen shows is a PREVIEW, not a state.
            -- 'incsearch' raises and drops `v:hlsearch` on every keystroke and swaps `@/` to the
            -- partial pattern for the duration of the preview — so acting on it here paints a
            -- counter for the PREVIOUS pattern and removes it again, once per character typed
            -- (measured: `hlsearch=1 pat="e"` → `hlsearch=0 pat="foo"` → repeat). What the user
            -- committed to is only knowable once the cmdline is left, which CmdlineLeave answers.
            if api.nvim_get_mode().mode:sub(1, 1) == "c" then
                return
            end
            local on = api.nvim_get_vvar("hlsearch") == 1
            if on and M.state == "IDLE" and config.auto_start and config.enabled then
                vim.schedule(M.start)
            elseif not on and M.state == "ACTIVE" then
                -- Always honoured, even with auto_start off: a search that is no longer highlighted
                -- has no lenses to keep, however the plugin was started.
                vim.schedule(M.stop)
            end
        end,
    })

    -- Which match is nearest, and which are on screen.
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = function()
            schedule()
        end,
    })
    -- WinScrolled's patterns are WINDOW IDS, not file names — so it is registered pattern-less and
    -- filtered by nothing; every scroll is a reason to re-slice the viewport.
    api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
        group = group,
        callback = function()
            schedule()
        end,
    })
    -- The positions themselves moved.
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = group,
        callback = function()
            schedule()
        end,
    })
    -- A different window, a different buffer: repaint at once rather than after the throttle.
    api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
        group = group,
        callback = function()
            schedule(true)
        end,
    })
    -- What counts as a match just changed under us; the cache keys on these, but nothing else would
    -- ask it to look again.
    api.nvim_create_autocmd("OptionSet", {
        group = group,
        pattern = { "ignorecase", "smartcase" },
        callback = function()
            schedule(true)
        end,
    })
    -- While a search is being TYPED, the matches highlighted on screen belong to the 'incsearch'
    -- preview of the partial pattern — not to the one our counters describe. Leaving the old lenses
    -- up would label the wrong matches, so they come down for the duration and the state is rebuilt
    -- from whatever the user actually commits to.
    api.nvim_create_autocmd("CmdlineEnter", {
        group = group,
        pattern = { "/", "?" },
        callback = function(ev)
            local pos = api.nvim_win_get_cursor(0)
            preview_origin = { lnum = pos[1], col = pos[2], forward = ev.match ~= "?" }
            preview_floor = 0
            if M.state == "ACTIVE" then
                M.stop()
            end
        end,
    })
    -- …and the pattern being typed is counted in its place. `v:hlsearch` is useless here (it flips
    -- per keystroke) and so is `@/` (it holds the OLD pattern outside the preview) — but the
    -- command line itself is exactly the pattern the user means, so it is read directly.
    api.nvim_create_autocmd("CmdlineChanged", {
        group = group,
        pattern = { "/", "?" },
        callback = function()
            if config.preview.enabled then
                M.preview(fn.getcmdline())
            end
        end,
    })
    -- A NEW pattern while the previous one was still highlighted. `CmdlineLeave` fires BEFORE the
    -- command runs, so the repaint is scheduled rather than done — by the time it lands, the search
    -- has executed and `@/` holds the new pattern.
    api.nvim_create_autocmd("CmdlineLeave", {
        group = group,
        pattern = { "/", "?", ":" },
        callback = function()
            preview_origin = nil
            vim.schedule(function()
                -- The sensor is deliberately blind while a cmdline is open, so this is where the
                -- committed state is read — one redraw earlier than the provider would see it.
                if config.enabled and config.auto_start and M.state == "IDLE" and vim.v.hlsearch == 1 then
                    M.start()
                else
                    schedule(true)
                end
            end)
        end,
    })
    -- A closed buffer keeps no lenses, and no entry in the cache.
    api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        callback = function(ev)
            painted[ev.buf] = nil
            matches.invalidate(ev.buf)
        end,
    })
end

--- Merge user options into the live config and start listening.
---@param opts LvimSearchConfig?
---@return nil
function M.setup(opts)
    merge(config, opts or {})
    highlights.setup()

    if not timer then
        timer = uv.new_timer()
    end

    if not ready then
        ready = true
        attach()

        api.nvim_create_user_command("LvimSearchToggle", function()
            M.toggle()
        end, { desc = "lvim-search: show or hide the search lenses" })

        api.nvim_create_user_command("LvimSearchRefresh", function()
            M.refresh()
        end, { desc = "lvim-search: repaint the search lenses now" })

        api.nvim_create_user_command("LvimSearchExport", function(ev)
            M.export({ scope = ev.args ~= "" and ev.args or nil })
        end, {
            nargs = "?",
            complete = function(lead)
                return vim.tbl_filter(function(scope)
                    return scope:find(lead, 1, true) == 1
                end, { "buffer", "all", "args" })
            end,
            desc = "lvim-search: send every match of the current search to the quickfix list",
        })
    end

    -- A repeat setup() with new formats or colours should be visible without waiting for the next
    -- search; the match cache is keyed on the buffer, not on the config, so it is dropped too.
    matches.invalidate()
    if M.state == "ACTIVE" then
        schedule(true)
    end
end

return M
