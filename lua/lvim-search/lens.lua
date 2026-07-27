-- lvim-search.lens: the thing you actually see — beside each visible match, the command that gets
-- you to it; beside the nearest, where you are in the whole set.
--
-- A LENS IS AN INSTRUCTION, NOT A LABEL. `[3n]` on a line means: type `3n` and you are there. An
-- absolute index (`[7]`) says which match it is and leaves the reader to count the presses
-- themselves, which is the arithmetic they wanted done for them. The nearest match keeps the
-- absolute reading — `[7/16]` — because that is the one place it answers a different question:
-- how far into the file you are.
--
-- ONE LENS PER LINE. Several matches on a line would otherwise stack labels on the same end-of-line
-- position, and the second one is unreadable. The line's lens names the FIRST match on it, except
-- when the nearest match is on that line, in which case the nearest wins the label — the reader's
-- own position is what a counter is for.
--
-- ONLY WHAT IS ON SCREEN. The list can hold a hundred thousand matches; the window shows a few
-- dozen lines. The renderer slices to `w0..w$` and places extmarks for that slice only, so the cost
-- of a refresh is bounded by the window, not by the file.
--
-- NO WINDOWS. When a line is too long for its lens to sit after the text, the same virtual text is
-- re-placed right-aligned on that screen line (`virt_text_pos = "right_align"`, verified accepted
-- here). Upstream opens a floating window for this case, with the shadow, z-index and blended
-- highlight clones that implies; a placement mode does the same job with nothing to own.
--
-- THE EMPHASIS IS NOT AN EXTMARK. Neovim draws 'hlsearch' ABOVE the whole extmark layer — measured:
-- an extmark at priority 5000 over a highlighted match still shows `Search`, because search
-- highlighting is not on the extmark priority scale at all. The layer it IS on is the one
-- `matchadd()` writes to, where `:h matchadd` puts 'hlsearch' at priority zero and anything above it
-- wins. So the nearest match is painted with `matchaddpos()`, which is per WINDOW rather than per
-- buffer — hence the separate bookkeeping and the separate clear.
--
---@module "lvim-search.lens"

local config = require("lvim-search.config")
local nearest = require("lvim-search.nearest")
local template = require("lvim-search.template")

local api = vim.api
local fn = vim.fn

local M = {}

---@type integer  the namespace every lens extmark lives in, so one clear removes them all
M.ns = api.nvim_create_namespace("LvimSearchLens")

---@type table<integer, integer[]>  window id → the match ids of the emphasis painted in it
local emphasis = {}
---@type table<integer, string>  window id → what that emphasis describes, so an unchanged one is
--- left alone. Rewriting a window's match list forces a full redraw of it, and a scroll repaints
--- many times a second while the nearest match does not move at all.
local emphasis_key = {}

--- The indicator for a match `steps` presses from the cursor — signed, positive meaning further
--- DOWN the buffer.
---
--- Two independent facts, kept independent: the ARROW says where the match lies (down the buffer or
--- up), the KEY says what to press. They are not the same thing — after a `?` search `n` travels
--- backwards, so an arrow that simply mirrored the key would point the wrong way half the time.
--- The count is omitted when one press does it, so the result reads as the exact command to type.
---@param steps integer
---@param forward boolean  `n` moves towards higher indices
---@return string
local function indicator_for(steps, forward)
    local ind = config.lens.indicator
    if not ind.enabled or steps == 0 then
        return ""
    end
    local down = steps > 0
    local count = math.abs(steps)
    return template.fill(ind.format, {
        arrow = down and ind.down or ind.up,
        key = (down == forward) and ind.forward or ind.backward,
        -- Empty when one press does it, so the indicator reads as the command you would type.
        count = count > 1 and tostring(count) or "",
    })
end

--- The lens body for one match, as extmark chunks.
---
--- `lens.format` is asked first and its answer is final — that is the whole extension point, and a
--- hook that can be overruled is not one. Returning nil from it falls back to the built-in shape,
--- so a user can restyle only the cases they care about.
---@param ctx table
---@return table[]? chunks
local function chunks_for(ctx)
    if type(config.lens.format) == "function" then
        local ok, custom = pcall(config.lens.format, ctx)
        if ok and type(custom) == "table" then
            return custom
        end
        if ok and custom ~= nil then
            -- A non-table, non-nil answer is a mistake worth ignoring rather than crashing a redraw.
            return nil
        end
    end

    local lens = config.lens
    local body
    if ctx.nearest then
        body = template.fill(lens.nearest_format, { current = ctx.current, total = ctx.total })
        if ctx.indicator ~= "" then
            body = ctx.indicator .. " " .. body
        end
    elseif ctx.indicator == "" then
        -- Nothing to say: no indicator and no counter would leave an empty pair of brackets, which
        -- is worse than an unlabelled line.
        return nil
    else
        body = template.fill(lens.other_format, { indicator = ctx.indicator })
    end

    local group = ctx.nearest and "LvimSearchLensNearest" or "LvimSearchLens"
    local chunks = {
        { lens.gap, "Normal" },
        { lens.wrap.left .. body .. lens.wrap.right, group },
    }

    -- The remaining counts come AFTER the bracket, not inside it. What is in the brackets is where
    -- the reader is and how to move; what follows is how much is left in each direction — a
    -- different fact, in its own accent, kept out of the counter it would otherwise crowd. Only on
    -- the nearest lens: one place, not one per line.
    local off = config.remaining
    if ctx.nearest and off.enabled then
        -- ONE box holding both counts, joined by `sep`. Wrapping each side separately looked
        -- equivalent and was not: at the junction the first side's right padding met the second's
        -- left padding, so the two values sat twice as far apart as either edge of the box.
        local parts = {}
        for _, side in ipairs({
            { glyph = off.above, count = ctx.above, tpl = off.format.above },
            { glyph = off.below, count = ctx.below, tpl = off.format.below },
        }) do
            if side.count > 0 and side.glyph ~= "" then
                parts[#parts + 1] = template.fill(side.tpl, { glyph = side.glyph, count = side.count })
            end
        end
        if #parts > 0 then
            local text = off.wrap.left .. table.concat(parts, off.sep) .. off.wrap.right
            chunks[#chunks + 1] = { text, "LvimSearchRemaining" }
        end
    end
    return chunks
end

--- How wide the chunks are, in display cells.
---@param chunks table[]
---@return integer
local function width_of(chunks)
    local n = 0
    for _, chunk in ipairs(chunks) do
        n = n + fn.strdisplaywidth(chunk[1])
    end
    return n
end

--- Would a lens of `width` cells still fit after the text of `lnum` in `win`?
---
--- Measured against the window's text area, so a sign column, number column and any fold column are
--- accounted for — the lens is placed after the LINE, and what matters is whether the result still
--- lands inside the window.
---@param win integer
---@param buf integer
---@param lnum integer
---@param width integer
---@return boolean
local function fits(win, buf, lnum, width)
    local line = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    local info = fn.getwininfo(win)[1]
    local textwidth = info and info.width - (info.textoff or 0) or api.nvim_win_get_width(win)
    return fn.strdisplaywidth(line) + width <= textwidth
end

--- Remove every lens from `buf`.
---@param buf integer
---@return nil
function M.clear(buf)
    if not api.nvim_buf_is_valid(buf) then
        return
    end
    api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
end

--- Remove the nearest-match emphasis from `win` (or from every window it was painted in).
---@param win integer?
---@return nil
function M.clear_emphasis(win)
    for id, ids in pairs(emphasis) do
        if win == nil or id == win then
            if api.nvim_win_is_valid(id) then
                for _, m in ipairs(ids) do
                    pcall(fn.matchdelete, m, id)
                end
            end
            emphasis[id] = nil
            emphasis_key[id] = nil
        end
    end
end

--- The match ids currently painted in `win` — for the fixtures, and for anything that wants to know
--- whether the emphasis is up without reading the screen.
---@param win integer
---@return integer[]
function M.emphasis_ids(win)
    return emphasis[win] or {}
end

--- Paint the lenses for `list` into `win`.
---@param win integer
---@param buf integer
---@param list LvimSearchMatch[]
---@param near LvimSearchNearest?
---@return integer placed  how many lenses were drawn
function M.render(win, buf, list, near)
    if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(buf) then
        return 0
    end
    M.clear(buf)
    if type(list) ~= "table" or #list == 0 then
        -- The lens marks are gone; the emphasis is on the window's match list and is settled by
        -- `emphasise` below, which is the only place allowed to touch it.
        M.emphasise(win, buf, list, near)
        return 0
    end

    local top, bot
    api.nvim_win_call(win, function()
        top, bot = fn.line("w0"), fn.line("w$")
    end)

    local above, below = M.remaining(list, near, top, bot)
    local placed, seen = 0, {}
    for index, m in ipairs(list) do
        local is_nearest = near ~= nil and near.index == index
        if m.lnum >= top and m.lnum <= bot then
            -- A folded line shows one summary row; a lens on it would label a line nobody can read.
            local folded = false
            api.nvim_win_call(win, function()
                folded = fn.foldclosed(m.lnum) ~= -1
            end)
            local skip = folded
                or (config.nearest_only and not is_nearest)
                -- One per line, unless this is the nearest — then it displaces the earlier label.
                or (seen[m.lnum] and not is_nearest)
            if not skip then
                if seen[m.lnum] then
                    api.nvim_buf_clear_namespace(buf, M.ns, m.lnum - 1, m.lnum)
                    placed = placed - 1
                end
                -- Written out rather than `near and near.forward or true`, which would answer true
                -- for a backwards search: `false or true` is true.
                local forward = true
                if near ~= nil then
                    forward = near.forward
                end
                local steps = near and nearest.steps(near, index) or 0
                local chunks = chunks_for({
                    buf = buf,
                    index = index,
                    current = near and near.index or index,
                    total = #list,
                    nearest = is_nearest,
                    forward = forward,
                    steps = steps,
                    indicator = indicator_for(steps, forward),
                    above = above,
                    below = below,
                    lnum = m.lnum,
                    col = m.col,
                })
                if chunks and #chunks > 0 then
                    -- Every lens, not just the nearest: an `eol` lens that runs past the window
                    -- edge is not clipped to something partial, it disappears entirely (measured).
                    local pos = "eol"
                    if not fits(win, buf, m.lnum, width_of(chunks)) then
                        if config.lens.overflow == "hide" then
                            chunks = nil
                        else
                            pos = config.lens.overflow
                        end
                    end
                    if chunks then
                        pcall(api.nvim_buf_set_extmark, buf, M.ns, m.lnum - 1, 0, {
                            virt_text = chunks,
                            virt_text_pos = pos,
                            hl_mode = config.lens.hl_mode,
                            priority = config.lens.priority,
                        })
                        seen[m.lnum] = true
                        placed = placed + 1
                    end
                end
            end
        end
    end

    M.emphasise(win, buf, list, near)
    return placed
end

--- How many matches lie each way — from the CURSOR or from the edges of the WINDOW, as configured.
---
--- The two answer different questions and neither is wrong. From the cursor: how many are left in
--- that direction, which is what an arrow beside a counter promises and what `x/y` already implies.
--- From the window: how many are not on screen, which is what you would gain by scrolling and is
--- not derivable from anything else — but it falls to zero while matches are plainly visible further
--- down, because they have not left the screen yet, and that reads as a bug even when it is not.
---@param list LvimSearchMatch[]
---@param near LvimSearchNearest?
---@param top integer   first visible line — only consulted for `from = "window"`
---@param bot integer   last visible line
---@return integer above, integer below
function M.remaining(list, near, top, bot)
    if #list == 0 then
        return 0, 0
    end
    if config.remaining.from == "window" then
        local above, below = 0, 0
        for _, m in ipairs(list) do
            if m.lnum < top then
                above = above + 1
            elseif m.lnum > bot then
                below = below + 1
            end
        end
        return above, below
    end
    if near == nil then
        return 0, 0
    end
    -- The match the counter names is neither behind nor ahead: it is where you are.
    return near.index - 1, #list - near.index
end

--- The `matchaddpos()` positions covering `m`: one `{lnum, col, len}` per line it touches.
---
--- `matchaddpos` counts columns from 1 and takes a LENGTH, not an end. A zero-width match (a `\zs`
--- pattern) is given one cell so that it is visible at all — an emphasis nobody can see is the same
--- as none.
---@param buf integer
---@param m LvimSearchMatch
---@return table[]
local function positions_of(buf, m)
    local last = m.end_lnum or m.lnum
    if last == m.lnum then
        return { { m.lnum, m.col + 1, math.max(1, m.end_col - m.col) } }
    end
    local out = {}
    for lnum = m.lnum, last do
        local line = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
        if lnum == m.lnum then
            out[#out + 1] = { lnum, m.col + 1, math.max(1, #line - m.col) }
        elseif lnum == last then
            out[#out + 1] = { lnum, 1, math.max(1, m.end_col) }
        else
            out[#out + 1] = { lnum, 1, math.max(1, #line) }
        end
    end
    return out
end

--- Paint the nearest match itself, when the cursor is not already standing on it.
---
--- `CurSearch` is Neovim's own highlight for the match under the cursor and it is always right about
--- that case; adding a second one there would be two highlights arguing. What it cannot do is mark
--- the match you are ABOUT to reach, which is exactly when this helps.
---@param win integer
---@param buf integer
---@param list LvimSearchMatch[]
---@param near LvimSearchNearest?
---@return boolean painted
function M.emphasise(win, buf, list, near)
    local m = near and list[near.index] or nil
    local wanted = nil
    if
        config.nearest_hl.enabled
        and near ~= nil
        and m ~= nil
        and api.nvim_win_is_valid(win)
        and not (config.nearest_hl.only_off_match and near.on_match)
    then
        wanted = ("%d:%d:%d:%d:%d"):format(m.lnum, m.col, m.end_lnum or m.lnum, m.end_col, config.nearest_hl.priority)
    end

    -- Nothing to do when it already describes this exact span. Worth the comparison: a window's
    -- match list cannot be edited in place, so refreshing it means matchdelete + matchaddpos, and
    -- THAT forces a full redraw of the window — every time, including the many repaints a single
    -- scroll produces while the nearest match has not moved.
    if emphasis_key[win] == wanted then
        return wanted ~= nil
    end

    M.clear_emphasis(win)
    if wanted == nil or m == nil then
        return false
    end

    -- `matchaddpos` takes at most 8 positions per call, so a match spanning more lines than that is
    -- painted by several — never truncated.
    local pos = positions_of(buf, m)
    local ids = {}
    for i = 1, #pos, 8 do
        local slice = vim.list_slice(pos, i, math.min(i + 7, #pos))
        local ok, id = pcall(fn.matchaddpos, "LvimSearchNearest", slice, config.nearest_hl.priority, -1, {
            window = win,
        })
        if ok and type(id) == "number" and id > 0 then
            ids[#ids + 1] = id
        end
    end
    emphasis[win] = ids
    emphasis_key[win] = wanted
    return #ids > 0
end

return M
