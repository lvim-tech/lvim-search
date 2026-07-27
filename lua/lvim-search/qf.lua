-- lvim-search.qf: turn the current search into a list you can walk.
--
-- The scan has already found every match and where it is; a quickfix list is that same information
-- in the form Neovim navigates with `:cnext`, `:cfdo` and every list UI in the editor. Building it
-- here costs nothing extra and means the plugin is not only a display.
--
-- WHY NOT `:vimgrep`. It would re-search the file from scratch, obey `'wildignore'`, load buffers,
-- and — the real objection — answer a DIFFERENT question: the pattern as `:vimgrep` parses it, not
-- the one currently highlighted with the case options currently in force. The list must agree with
-- what is on screen, so it is built from the same match list the lenses were drawn from.
--
-- `on_list` mirrors the convention Neovim's own LSP handlers use: give the caller the raw items and
-- let them put them wherever they want (a picker, a location list, a scratch buffer), instead of
-- offering a menu of destinations nobody can extend.
--
---@module "lvim-search.qf"

local config = require("lvim-search.config")
local matches = require("lvim-search.matches")
local template = require("lvim-search.template")

local api = vim.api
local fn = vim.fn

local M = {}

--- The quickfix items for every match of the current search in `buf`.
---@param buf integer
---@param pattern string
---@return table[]? items, LvimSearchList? list
local function items_for(buf, pattern)
    local list = matches.get(buf, pattern)
    if not list or list.total == 0 then
        return nil, nil
    end
    local items = {}
    for _, m in ipairs(list.matches) do
        -- The whole LINE is the entry's text, not the matched fragment: a quickfix list of a hundred
        -- rows reading "foo" is unusable, and the column already says where on the line it is.
        local text = api.nvim_buf_get_lines(buf, m.lnum - 1, m.lnum, false)[1] or m.text
        items[#items + 1] = {
            bufnr = buf,
            lnum = m.lnum,
            col = m.col + 1, -- quickfix columns are 1-based
            end_lnum = m.end_lnum or m.lnum,
            end_col = m.end_col + 1,
            text = text,
            type = "I",
        }
    end
    return items, list
end

--- The buffers a scope covers, in a stable order.
---
--- Only LOADED buffers: `matchbufline()` reads a buffer's lines, and loading files behind the user's
--- back to search them is a side effect they did not ask for — `:LvimSearchExport` is not `:grep`.
--- What is skipped is counted and reported rather than silently dropped.
---@param scope string
---@return integer[] bufs, integer skipped
local function buffers_for(scope)
    if scope == "buffer" then
        return { api.nvim_get_current_buf() }, 0
    end

    local wanted, out, skipped = {}, {}, 0
    if scope == "args" then
        for i = 0, fn.argc() - 1 do
            local name = fn.argv(i)
            local buf = fn.bufnr(name --[[@as string]])
            wanted[#wanted + 1] = buf
        end
    else
        wanted = api.nvim_list_bufs()
    end

    for _, buf in ipairs(wanted) do
        if buf > 0 and api.nvim_buf_is_valid(buf) then
            -- `buflisted` keeps the sweep to the user's own files: help buffers, terminals and
            -- plugin scratch panels are not what "search everything I have open" means.
            if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
                out[#out + 1] = buf
            else
                skipped = skipped + 1
            end
        else
            skipped = skipped + 1
        end
    end
    return out, skipped
end

--- Send the current search to the quickfix list (or to `on_list`, when the user set one).
---@param opts { scope: "buffer"|"all"|"args"|nil, buf: integer? }?
---@return integer count  how many items were exported
function M.export(opts)
    opts = opts or {}
    local scope = opts.scope or "buffer"
    if scope ~= "buffer" and scope ~= "all" and scope ~= "args" then
        vim.notify(("lvim-search: unknown scope %q (buffer, all, args)"):format(scope), vim.log.levels.ERROR)
        return 0
    end

    local pattern = fn.getreg("/")
    if type(pattern) ~= "string" or pattern == "" then
        vim.notify("lvim-search: no search pattern", vim.log.levels.WARN)
        return 0
    end

    local bufs, skipped = buffers_for(scope)
    if opts.buf then
        bufs = { opts.buf }
    end

    local items, capped, searched = {}, false, 0
    for _, buf in ipairs(bufs) do
        local part, list = items_for(buf, pattern)
        if part and list then
            searched = searched + 1
            capped = capped or list.capped
            vim.list_extend(items, part)
        end
    end

    if #items == 0 then
        vim.notify(("lvim-search: no matches for %s"):format(pattern), vim.log.levels.WARN)
        return 0
    end

    local title = scope == "buffer" and template.fill(config.qf.title, { pattern = pattern })
        or template.fill(config.qf.title_scoped, { pattern = pattern, buffers = searched })

    if type(config.on_list) == "function" then
        config.on_list({
            items = items,
            title = title,
            context = { pattern = pattern, capped = capped, scope = scope, buffers = searched },
        })
        return #items
    end

    fn.setqflist({}, " ", { title = title, items = items })
    vim.cmd("botright copen")

    if capped then
        vim.notify(
            ("lvim-search: a buffer stopped at scan.max_matches (%d)"):format(config.scan.max_matches),
            vim.log.levels.WARN
        )
    end
    if skipped > 0 then
        vim.notify(("lvim-search: skipped %d unloaded or unlisted buffer(s)"):format(skipped), vim.log.levels.INFO)
    end
    return #items
end

return M
