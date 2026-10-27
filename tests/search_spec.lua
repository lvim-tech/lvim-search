-- Where the matches are, and which one the reader is on.
--
-- Both modules say in their own headers exactly what they promise and why, and both are pure
-- enough to hold to it: matches.lua is "positions, not a count", keyed by everything that can
-- change the answer; nearest.lua answers "a position among sorted positions" with no cursor
-- movement at all. The number the lens shows -- `3/10`, `2n` -- is nearest.steps(), and it is
-- counted the way the KEYS behave, which is where the off-by-one between "on a match" and
-- "between two matches" comes from.

local matches = require("lvim-search.matches")
local nearest = require("lvim-search.nearest")
local config = require("lvim-search.config")

--- A buffer holding `lines`, current, with a clean cache.
---@param lines string[]
---@return integer buf
local function given(lines)
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    matches.invalidate(buf)
    return buf
end

--- Match positions as "lnum:col-end_lnum:end_col" strings.
---@param list LvimSearchList|nil
---@return string[]
local function spans(list)
    local out = {}
    for i, m in ipairs(list and list.matches or {}) do
        out[i] = ("%d:%d-%d:%d"):format(m.lnum, m.col, m.end_lnum, m.end_col)
    end
    return out
end

describe("lvim-search: where the matches are")

it("every match is reported with byte columns", function()
    local buf = given({ "foo bar foo", "baz", "foo" })
    eq({ "1:0-1:3", "1:8-1:11", "3:0-3:3" }, spans(matches.get(buf, "foo")))
end)

it("byte columns are right on multibyte text", function()
    local buf = given({ "кирилица foo" })
    -- "кирилица" is eight two-byte characters, then a space: the match starts at byte 17.
    eq({ "1:17-1:20" }, spans(matches.get(buf, "foo")))
end)

it("the scan honours 'ignorecase'", function()
    local buf = given({ "Foo", "foo" })
    local was = vim.o.ignorecase
    vim.o.ignorecase = false
    eq({ "1:0-1:3" }, spans(matches.get(buf, "Foo")))
    vim.o.ignorecase = true
    eq({ "1:0-1:3", "2:0-2:3" }, spans(matches.get(buf, "Foo")), "and the cache key knows the option changed")
    vim.o.ignorecase = was
end)

it("a pattern that crosses lines is found by the bounded walk", function()
    local buf = given({ "foo bar foo", "baz", "foo" })
    -- matchbufline cannot match across lines at all, which is why there is a second path.
    eq({ "1:8-2:3" }, spans(matches.get(buf, "foo\\nbaz")))
end)

it("a malformed pattern is nothing to render, not an error", function()
    local buf = given({ "foo" })
    eq(nil, matches.get(buf, "\\("), "the reader is still typing; the next keystroke answers")
    eq(nil, matches.get(buf, ""))
    eq(nil, matches.get(buf, nil))
end)

it("nothing matching is an empty list, not a missing one", function()
    local buf = given({ "foo" })
    local list = matches.get(buf, "zzz")
    truthy(list, "an empty answer must be distinguishable from a refusal")
    eq(0, list.total)
end)

it("an edit invalidates the cached answer", function()
    local buf = given({ "foo" })
    eq(1, matches.get(buf, "foo").total)
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "foo again" })
    eq(2, matches.get(buf, "foo").total, "the key carries changedtick")
end)

it("an unchanged buffer is answered from the cache, by identity", function()
    local buf = given({ "foo" })
    local first = matches.get(buf, "foo")
    local second = matches.get(buf, "foo")
    truthy(rawequal(first, second), "the same list object, i.e. no rescan")
end)

it("the scan stops at the cap and says so", function()
    local lines = {}
    for i = 1, 50 do
        lines[i] = "foo"
    end
    local buf = given(lines)
    local was = config.scan.max_matches
    config.scan.max_matches = 10
    matches.invalidate(buf)
    local list = matches.get(buf, "foo")
    config.scan.max_matches = was
    matches.invalidate(buf)

    eq(true, list.capped, "a truncated list that did not say so would read as the whole truth")
    eq(10, list.total)
end)

describe("lvim-search: which match the cursor is on")

--- The match list of `pattern` over `lines`.
---@param lines string[]
---@param pattern string
---@return LvimSearchMatch[]
local function list_of(lines, pattern)
    return matches.get(given(lines), pattern).matches
end

it("the cursor inside a match is on it", function()
    local l = list_of({ "foo bar foo" }, "foo")
    eq(true, nearest.of(l, 1, 0).on_match)
    eq(true, nearest.of(l, 1, 2).on_match, "the last byte of the match counts")
    eq(1, nearest.of(l, 1, 1).index)
end)

it("the end column is exclusive", function()
    local l = list_of({ "foo bar foo" }, "foo")
    eq(false, nearest.of(l, 1, 3).on_match, "column 3 is the space after foo")
end)

it("a zero-width match is only matched by standing exactly on it", function()
    local l = { { lnum = 1, col = 2, end_lnum = 1, end_col = 2, text = "" } }
    eq(true, nearest.of(l, 1, 2).on_match)
    eq(false, nearest.of(l, 1, 1).on_match)
    eq(false, nearest.of(l, 1, 3).on_match)
end)

it("a match that crosses lines contains every position between its ends", function()
    local l = { { lnum = 1, col = 8, end_lnum = 3, end_col = 2, text = "" } }
    eq(true, nearest.of(l, 1, 9).on_match)
    eq(true, nearest.of(l, 2, 0).on_match, "the whole of the line in the middle is inside it")
    eq(true, nearest.of(l, 3, 1).on_match)
    eq(false, nearest.of(l, 3, 2).on_match, "and the end is still exclusive")
    eq(false, nearest.of(l, 1, 7).on_match)
end)

it("a cursor before every match names the first, and after them all the last", function()
    local l = list_of({ "x", "foo", "y", "foo" }, "foo")
    eq(1, nearest.of(l, 1, 0).index)
    eq(2, nearest.of(l, 4, 99).index)
end)

it("a cursor exactly between two matches names the one `n` would reach", function()
    -- Equal buffer distance either way: the tie goes FORWARD, because `n` is the key about to
    -- be pressed.
    local l = list_of({ "foo", "x", "foo" }, "foo")
    eq(2, nearest.of(l, 2, 0).index)
end)

it("an empty list has no answer at all", function()
    eq(nil, nearest.of({}, 1, 0))
    eq(nil, nearest.of(nil, 1, 0))
end)

describe("lvim-search: how many presses away")

it("standing on a match, the count is the plain index difference", function()
    local l = list_of({ "foo", "foo", "foo" }, "foo")
    local near = nearest.of(l, 1, 0)
    eq(true, near.on_match)
    eq(0, nearest.steps(near, 1), "no presses to where you already are")
    eq(1, nearest.steps(near, 2))
    eq(2, nearest.steps(near, 3))

    local from_last = nearest.of(l, 3, 0)
    eq(-2, nearest.steps(from_last, 1), "the count is signed: negative travels up the buffer")
end)

it("standing between two matches, `N` is one press and the count shifts by one", function()
    local l = list_of({ "foo", "x", "foo" }, "foo")
    local near = nearest.of(l, 2, 0)
    eq(false, near.on_match)
    eq(1, near.before, "the last match at or before the cursor")
    eq(1, nearest.steps(near, 2), "the match below is one `n`")
    eq(-1, nearest.steps(near, 1), "the match above is one `N`, not zero")
end)

it("the reported distance is the number of presses to the nearest one", function()
    local l = list_of({ "foo", "x", "foo" }, "foo")
    eq(0, nearest.of(l, 1, 0).rel, "on it")
    eq(1, nearest.of(l, 2, 0).rel, "one away")
end)

describe("lvim-search: where a previewed search will land")

it("a forward search lands on the first match strictly after the cursor", function()
    local l = list_of({ "foo", "foo" }, "foo")
    local dest = nearest.destination(l, { lnum = 1, col = 0, forward = true })
    eq(2, dest.index, "being on match 1 does not count as finding it")
    eq(true, dest.on_match, "shaped as if the jump had already happened")
    eq(0, dest.rel, "so no lens number shifts at the <CR>")
end)

it("a backward search lands on the last match strictly before the cursor", function()
    local l = list_of({ "foo", "foo", "foo" }, "foo")
    eq(2, nearest.destination(l, { lnum = 3, col = 0, forward = false }).index)
    eq(
        1,
        nearest.destination(l, { lnum = 2, col = 0, forward = false }).index,
        "sitting on a match's first byte means that match is not before anything"
    )
end)

it("past the last match it wraps, unless 'wrapscan' is off", function()
    local l = list_of({ "foo", "foo" }, "foo")
    local was = vim.o.wrapscan

    vim.o.wrapscan = true
    eq(1, nearest.destination(l, { lnum = 2, col = 0, forward = true }).index)
    eq(2, nearest.destination(l, { lnum = 1, col = 0, forward = false }).index)

    vim.o.wrapscan = false
    eq(
        nil,
        nearest.destination(l, { lnum = 2, col = 0, forward = true }),
        "the search will fail; do not invent a destination"
    )
    eq(nil, nearest.destination(l, { lnum = 1, col = 0, forward = false }))

    vim.o.wrapscan = was
end)

describe("lvim-search: nearest measured in screen rows")

it("a fold between the cursor and a match shortens the distance it is judged by", function()
    -- The option exists because buffer distance and screen distance disagree exactly when a fold
    -- or a wrap sits between the candidates. Built so they disagree: the match ABOVE is nearer in
    -- buffer lines, but everything between the cursor and the one BELOW is folded away.
    local lines = { "foo" }
    for i = 2, 12 do
        lines[i] = "filler " .. i
    end
    lines[13] = "foo"
    local buf = given(lines)
    local l = matches.get(buf, "foo").matches
    eq(2, #l)

    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    local by_buffer = nearest.of(l, 6, 0)
    eq(1, by_buffer.index, "five lines up beats seven lines down")

    vim.wo.foldmethod = "manual"
    vim.cmd("7,12fold")
    truthy(vim.fn.foldclosed(8) > 0, "precondition: the lines below the cursor really are folded")

    local was = config.nearest_by
    config.nearest_by = "screen"
    local by_screen = nearest.of(l, 6, 0, vim.api.nvim_get_current_win())
    config.nearest_by = was
    vim.cmd("normal! zE")

    eq(2, by_screen.index, "on screen the folded six lines cost one row, so the match below is closer")
end)
