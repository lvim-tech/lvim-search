-- lvim-search.matches: WHERE the search pattern matches, for a whole buffer, cached.
--
-- The lens needs POSITIONS, not a count. `searchcount()` answers "how many" and refuses to say
-- where, so it cannot drive a per-match decoration — it is kept for the degraded mode below and as
-- the cross-check the fixtures compare against.
--
-- `matchbufline()` is the answer: it runs Vim's own regex engine over a buffer in C and returns
-- every match with its line and BYTE index, without moving the cursor, without a quickfix detour and
-- without touching the search register. Measured here: it honours `'ignorecase'`, reports byte
-- offsets correctly on multibyte text (24 on a Cyrillic line), and raises a catchable `E54` on a
-- malformed pattern rather than aborting.
--
-- ITS ONE LIMIT, measured rather than assumed: it does not match across lines — `foo\nB` returns
-- nothing. A pattern that CAN cross lines is therefore routed to a bounded `searchpos` walk, which
-- is slower but correct, and only for the patterns that need it.
--
-- CACHING. A scan is keyed by everything that can change its answer: the buffer's `changedtick`,
-- the pattern, and the case options in force. Anything else would hand back a stale list after an
-- edit or after `:set ic`. The cache is an LRU over buffers rather than a wipe-everything, so
-- alternating between two files does not rescan both every time.
--
---@module "lvim-search.matches"

local config = require("lvim-search.config")

local api = vim.api
local fn = vim.fn

local M = {}

---@class LvimSearchMatch
---@field lnum integer   1-based
---@field col integer    0-based byte column of the match start
---@field end_lnum integer  1-based line the match ENDS on; equal to `lnum` for all but a pattern
---   that crosses lines, which only the bounded walk can produce
---@field end_col integer  0-based byte column just past the match, on `end_lnum`
---@field text string

---@class LvimSearchList
---@field matches LvimSearchMatch[]
---@field capped boolean   the scan hit `scan.max_matches` and stopped
---@field total integer    how many are in `matches` (the capped count when capped)
---@field pattern string
---@field key string       the fingerprint this list was built for

---@type table<integer, LvimSearchList>  buf → its cached list
local cache = {}
---@type integer[]  buffers in use order, most recent last (the LRU)
local order = {}

--- Everything that can change what a scan returns.
---
--- `'smartcase'` only matters through `'ignorecase'`, but both are in the key because a user can
--- flip either one, and a fingerprint that is too coarse hands back a wrong list — while one that is
--- too fine only costs a rescan.
---@param buf integer
---@param pattern string
---@return string
local function fingerprint(buf, pattern)
    return ("%d:%s:%s:%s"):format(
        api.nvim_buf_get_changedtick(buf),
        pattern,
        tostring(vim.o.ignorecase),
        tostring(vim.o.smartcase)
    )
end

--- Remember `buf` as most recently used and evict past `scan.cache_buffers`.
---@param buf integer
---@return nil
local function touch(buf)
    for i, b in ipairs(order) do
        if b == buf then
            table.remove(order, i)
            break
        end
    end
    order[#order + 1] = buf
    local limit = math.max(1, tonumber(config.scan.cache_buffers) or 8)
    while #order > limit do
        local evicted = table.remove(order, 1)
        cache[evicted] = nil
    end
end

--- Can this pattern match across a line break?
---
--- A substring test on `\n` and `\_`, which are the two ways a Vim pattern reaches past the end of a
--- line. It is deliberately generous: a false POSITIVE costs the slower walk on a pattern that did
--- not need it, while a false negative silently loses matches. Escaped literals (`\\n`) are excluded
--- so a search for a backslash followed by `n` is not misread.
---@param pattern string
---@return boolean
local function multiline_pattern(pattern)
    local scan = pattern:gsub("\\\\", "")
    return scan:find("\\n", 1, true) ~= nil or scan:find("\\_", 1, true) ~= nil
end

--- Scan with `matchbufline` — the whole buffer in one call.
---@param buf integer
---@param pattern string
---@param cap integer
---@return LvimSearchMatch[]?, boolean capped
local function scan_fast(buf, pattern, cap)
    local ok, raw = pcall(fn.matchbufline, buf, pattern, 1, "$")
    if not ok or type(raw) ~= "table" then
        return nil, false
    end
    -- `matchbufline` answers one dict per match — see `:help matchbufline()`; the vim.fn signature
    -- does not carry that shape.
    ---@cast raw { lnum: integer, byteidx: integer, text: string }[]
    local out, capped = {}, false
    for _, m in ipairs(raw) do
        if #out >= cap then
            capped = true
            break
        end
        local text = m.text or ""
        out[#out + 1] = {
            lnum = m.lnum,
            col = m.byteidx,
            -- `matchbufline` works line by line, so every match it can find ends where it began.
            end_lnum = m.lnum,
            end_col = m.byteidx + #text,
            text = text,
        }
    end
    return out, capped
end

--- Scan with a bounded `searchpos` walk, for a pattern that can cross lines.
---
--- The cursor is saved and restored around it, and the walk is bounded twice — by the cap and by a
--- wall-clock budget — because a pathological pattern on a large buffer must cost a stutter, never
--- a hang.
---@param buf integer
---@param pattern string
---@param cap integer
---@return LvimSearchMatch[]?, boolean capped
local function scan_multiline(buf, pattern, cap)
    local win = fn.bufwinid(buf)
    if win == -1 then
        -- Without a window there is no cursor to walk, and moving to one would be a side effect the
        -- caller never asked for. The fast scanner's answer (possibly empty) stands.
        return nil, false
    end
    local budget = math.max(1, tonumber(config.scan.multiline_timeout) or 100)
    local out, capped = {}, false
    api.nvim_win_call(win, function()
        local view = fn.winsaveview()
        local started = vim.uv.now()
        api.nvim_win_set_cursor(win, { 1, 0 })
        local first = true
        while true do
            local flags = first and "cW" or "W"
            first = false
            local ok, pos = pcall(fn.searchpos, pattern, flags)
            if not ok or type(pos) ~= "table" or pos[1] == 0 then
                break
            end
            local ok_end, epos = pcall(fn.searchpos, pattern, "cen")
            local lnum, col = pos[1], pos[2] - 1
            local end_lnum, end_col = lnum, col
            if ok_end and type(epos) == "table" and epos[1] >= lnum then
                -- The true end, wherever it landed: a `\n` pattern ends on a LATER line, and a
                -- record that pretended otherwise would make the emphasis paint the wrong span.
                end_lnum, end_col = epos[1], epos[2]
            end
            out[#out + 1] = {
                lnum = lnum,
                col = col,
                end_lnum = end_lnum,
                end_col = end_lnum == lnum and math.max(end_col, col) or end_col,
                text = "",
            }
            if #out >= cap then
                capped = true
                break
            end
            if vim.uv.now() - started > budget then
                capped = true
                break
            end
        end
        fn.winrestview(view)
    end)
    return out, capped
end

--- Every match of `pattern` in `buf`, from the cache when nothing that matters has changed.
---@param buf integer
---@param pattern string
---@return LvimSearchList?
function M.get(buf, pattern)
    if not api.nvim_buf_is_valid(buf) or pattern == nil or pattern == "" then
        return nil
    end
    local key = fingerprint(buf, pattern)
    local hit = cache[buf]
    if hit and hit.key == key then
        touch(buf)
        return hit
    end

    local cap = math.max(1, tonumber(config.scan.max_matches) or 100000)
    local matches, capped
    if config.scan.multiline ~= false and multiline_pattern(pattern) then
        matches, capped = scan_multiline(buf, pattern, cap)
    end
    if matches == nil then
        matches, capped = scan_fast(buf, pattern, cap)
    end
    if matches == nil then
        -- A malformed pattern is the user still typing, not an error to report: the caller renders
        -- nothing and the next keystroke answers.
        return nil
    end

    local list = {
        matches = matches,
        capped = capped == true,
        total = #matches,
        pattern = pattern,
        key = key,
    }
    cache[buf] = list
    touch(buf)

    if type(config.on_list) == "function" then
        pcall(config.on_list, matches, buf, api.nvim_buf_get_changedtick(buf), pattern)
    end
    return list
end

--- What a capped buffer can still say: the count, from `searchcount`, without positions.
---
--- The honest degraded mode. Upstream answers an oversized buffer with an empty list, which is
--- indistinguishable from "no matches" — the one thing the reader must not be told wrongly.
---@param pattern string
---@return { current: integer, total: integer, incomplete: integer }?
function M.count(pattern)
    local ok, res = pcall(fn.searchcount, { pattern = pattern, recompute = true, maxcount = 0, timeout = 100 })
    if not ok or type(res) ~= "table" or res.total == nil then
        return nil
    end
    return { current = res.current or 0, total = res.total or 0, incomplete = res.incomplete or 0 }
end

--- Forget a buffer's list, or every list.
---@param buf integer?
---@return nil
function M.invalidate(buf)
    if buf then
        cache[buf] = nil
        for i, b in ipairs(order) do
            if b == buf then
                table.remove(order, i)
                break
            end
        end
        return
    end
    cache, order = {}, {}
end

return M
