-- lvim-search.nearest: which match the reader is on, or heading towards.
--
-- Everything the lens says depends on this: the `3/10`, the `2n` prefix, which line gets the bright
-- treatment. It is a question about the BUFFER — a position among sorted positions — so it is
-- answered by binary search over the match starts, in Lua, with no cursor movement at all.
--
-- WHY NOT SCREEN DISTANCE. Upstream decides "nearest" by physically moving the cursor to each
-- candidate and reading `winline()`. That is accurate about folds and wrapping, and it costs two
-- cursor jumps on every refresh — jumps that other plugins' `CursorMoved` handlers can see. The
-- deviation is visible only when a fold or a long wrap sits between the two candidates, and the
-- price of matching it exactly is side effects in someone else's autocmds. Buffer distance it is —
-- by default. `nearest_by = "screen"` switches the comparison to `nvim_win_text_height`, which
-- answers the folds-and-wrapping question exactly, and answers it without moving anything.
--
-- DIRECTION. `v:searchforward` says whether `n` goes down or up, and the relative index is counted
-- in that direction — so the prefix reads as the number of `n` presses that would land you there,
-- which is the only number worth showing.
--
---@module "lvim-search.nearest"

local config = require("lvim-search.config")

local api = vim.api
local fn = vim.fn

local M = {}

---@class LvimSearchNearest
---@field index integer     1-based index into the match list
---@field on_match boolean  the cursor is inside that match
---@field forward boolean   `n` moves towards higher indices
---@field before integer    index of the last match starting at or before the cursor; 0 when the
---   cursor precedes all of them. Everything about "how far" is measured from here.
---@field rel integer       how many presses away the nearest match is; 0 when the cursor is on it

--- Is `(lnum, col)` at or after the start of `m`?
---@param m LvimSearchMatch
---@param lnum integer
---@param col integer
---@return boolean
local function starts_at_or_before(m, lnum, col)
    if m.lnum ~= lnum then
        return m.lnum < lnum
    end
    return m.col <= col
end

--- The index of the last match starting at or before the cursor, or 0 when the cursor precedes all
--- of them. Binary search: the list is sorted by construction, and a linear walk on a 100k-match
--- buffer would be paid on every cursor move.
---@param list LvimSearchMatch[]
---@param lnum integer
---@param col integer
---@return integer
local function floor_index(list, lnum, col)
    local lo, hi, answer = 1, #list, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if starts_at_or_before(list[mid], lnum, col) then
            answer = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return answer
end

--- Distance from the cursor to a match, in (lines, columns). Compared lexicographically, which is
--- what "nearer" means in a buffer: a match one line away is farther than any match on this line.
---@param m LvimSearchMatch
---@param lnum integer
---@param col integer
---@return integer lines, integer cols
local function distance(m, lnum, col)
    return math.abs(m.lnum - lnum), math.abs(m.col - col)
end

--- How many SCREEN rows separate two buffer lines in `win`.
---
--- `nvim_win_text_height` answers what buffer arithmetic cannot: a closed fold between the two lines
--- costs one row however many lines it hides, and a wrapped line costs several — measured, 10 rows
--- spanning a 6-line fold report 7, and 6 wrapped rows report 8. This is the whole reason the option
--- exists, and it is done without moving the cursor, which is why it can be a default-off option
--- rather than a rejected idea.
---@param win integer
---@param a integer  1-based line
---@param b integer  1-based line
---@return integer
local function screen_distance(win, a, b)
    if a == b then
        return 0
    end
    local lo, hi = math.min(a, b), math.max(a, b)
    local ok, height = pcall(api.nvim_win_text_height, win, { start_row = lo - 1, end_row = hi - 1 })
    if not ok or type(height) ~= "table" or type(height.all) ~= "number" then
        return math.abs(b - a)
    end
    -- The range includes both end lines; what is wanted is the gap between them.
    return math.max(0, height.all - 1)
end

--- Which match the cursor is on or nearest to.
---@param list LvimSearchMatch[]
---@param lnum integer   1-based cursor line
---@param col integer    0-based cursor column
---@param win integer?   the window to measure SCREEN distance in, when `nearest_by = "screen"`
---@return LvimSearchNearest?
function M.of(list, lnum, col, win)
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    local forward = fn.exists("v:searchforward") == 1 and vim.v.searchforward == 1 or false

    local before = floor_index(list, lnum, col)
    local index

    -- On a match? Only the one starting at or before the cursor can contain it. The end is
    -- exclusive — except for a zero-width match, where start and end coincide and being "on" it
    -- means standing exactly there. A match that crosses lines contains every position from its
    -- start to its end, so the comparison is on (line, col) pairs rather than on columns alone.
    local candidate = before > 0 and list[before] or nil
    local on_match = false
    if candidate ~= nil then
        local end_lnum = candidate.end_lnum or candidate.lnum
        local zero_width = end_lnum == candidate.lnum and candidate.end_col == candidate.col
        local at_or_after_start = lnum > candidate.lnum or (lnum == candidate.lnum and col >= candidate.col)
        local before_end = lnum < end_lnum or (lnum == end_lnum and col < candidate.end_col)
        on_match = at_or_after_start
            and (before_end or (zero_width and lnum == candidate.lnum and col == candidate.col))
    end

    if on_match then
        index = before
    elseif before == 0 then
        index = 1
    elseif before >= #list then
        index = #list
    else
        local a_lines, a_cols = distance(list[before], lnum, col)
        local b_lines, b_cols = distance(list[before + 1], lnum, col)
        if config.nearest_by == "screen" and win ~= nil and api.nvim_win_is_valid(win) then
            -- The same comparison, in rows the reader can actually see.
            a_lines = screen_distance(win, lnum, list[before].lnum)
            b_lines = screen_distance(win, lnum, list[before + 1].lnum)
        end
        -- The tie goes FORWARD: with the cursor exactly between two matches, `n` is the key the
        -- reader is about to press, so the one it would reach is the one to name.
        if a_lines < b_lines or (a_lines == b_lines and a_cols < b_cols) then
            index = before
        else
            index = before + 1
        end
    end

    local answer = { index = index, on_match = on_match, forward = forward, before = before, rel = 0 }
    answer.rel = math.abs(M.steps(answer, index))
    return answer
end

--- How many presses of `n`/`N` separate the cursor from match `i`, SIGNED: positive travels down
--- the buffer (higher indices), negative up.
---
--- This is the number the reader can act on, so it is counted the way the keys actually behave.
--- `n` from anywhere lands on the first match after the cursor — match `before + 1` — so a match
--- `k` positions further down is `k` presses away. `N` lands on the match before the cursor: that is
--- match `before` when the cursor sits between two matches (one press), but match `before - 1` when
--- the cursor is already inside match `before` (which is why the two cases differ by one).
---
--- Deliberately NOT counted around the end of the file: a match one line above the cursor is one
--- `N` away, and reporting it as "15 presses of n, the long way round" is arithmetically true and
--- useless.
---@param near LvimSearchNearest
---@param i integer   index into the same list `near` was computed from
---@return integer
function M.steps(near, i)
    if near.on_match then
        return i - near.before
    end
    return i > near.before and (i - near.before) or (i - near.before - 1)
end

--- Where a search would LAND, given where the cursor was when the pattern was typed.
---
--- Needed because a pattern being previewed is counted from the wrong place otherwise: 'incsearch'
--- moves the cursor to the previewed match — measured, to one past its END — so reading the live
--- cursor answers "how far from the preview", which is a position the reader never chose. The
--- question they mean is "what will I get when I press <CR>", and that is derivable from where they
--- were when they opened the command line.
---
--- The answer is shaped as if the jump had already happened (`on_match`, zero steps), so every other
--- lens shows the `n`/`N` count it will have a moment later. Typing the pattern and committing it
--- then show the same numbers, instead of every lens shifting by one at the <CR>.
---@param list LvimSearchMatch[]
---@param origin { lnum: integer, col: integer, forward: boolean }
---@return LvimSearchNearest?
function M.destination(list, origin)
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    local before = floor_index(list, origin.lnum, origin.col)
    local index

    if origin.forward then
        -- `/` lands on the first match STRICTLY after the cursor — being on one does not count.
        index = before + 1
        if index > #list then
            index = vim.o.wrapscan and 1 or nil
        end
    else
        -- `?` lands on the last match starting strictly before the cursor. Sitting exactly on a
        -- match's first byte means that match is not "before" anything.
        index = before
        if index > 0 and list[index].lnum == origin.lnum and list[index].col == origin.col then
            index = index - 1
        end
        if index < 1 then
            index = vim.o.wrapscan and #list or nil
        end
    end

    if index == nil then
        -- With 'nowrapscan' there is nowhere to go: the search will fail, and claiming a
        -- destination would be inventing one.
        return nil
    end
    return { index = index, on_match = true, forward = origin.forward, before = index, rel = 0 }
end

--- The same, for the cursor of `win`.
---@param list LvimSearchMatch[]
---@param win integer?
---@return LvimSearchNearest?
function M.of_cursor(list, win)
    win = win or api.nvim_get_current_win()
    if not api.nvim_win_is_valid(win) then
        return nil
    end
    local pos = api.nvim_win_get_cursor(win)
    return M.of(list, pos[1], pos[2], win)
end

return M
