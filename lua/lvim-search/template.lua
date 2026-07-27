-- lvim-search.template: the `{name}` substitution every configurable format string is written in.
--
-- WHY NOT `string.format`. `"%s%d"` fixes the ORDER of its values as surely as it fixes their types:
-- putting the number before the glyph would mean editing the code that calls it, because Lua has no
-- positional specifiers (`%1$s`) to reorder them from the template. A named placeholder carries its
-- own meaning, so `"{glyph}{count}"` and `"{count}{glyph}"` are both just strings a user can type —
-- which is the whole point of the option existing.
--
-- It also reads better: `"{current}/{total}"` says what it renders, where `"%d/%d"` only says how
-- many numbers it wants.
--
-- UNKNOWN NAMES ARE LEFT ALONE, not erased. A typo renders as `{cout}` on screen, where it is
-- obvious and fixable; silently swallowing it would leave the user with a gap and no clue. Health
-- names them explicitly.
--
---@module "lvim-search.template"

local M = {}

--- Fill `{name}` placeholders in `tpl` from `values`.
---@param tpl string
---@param values table<string, string|number>
---@return string
function M.fill(tpl, values)
    if type(tpl) ~= "string" then
        return ""
    end
    return (
        tpl:gsub("{(%w+)}", function(name)
            local v = values[name]
            if v == nil then
                -- Left verbatim: see the note above.
                return "{" .. name .. "}"
            end
            return tostring(v)
        end)
    )
end

--- Every `{name}` a template asks for, in order of appearance.
---@param tpl string
---@return string[]
function M.names(tpl)
    local out = {}
    if type(tpl) ~= "string" then
        return out
    end
    for name in tpl:gmatch("{(%w+)}") do
        out[#out + 1] = name
    end
    return out
end

--- The names a template uses that are not in `known` — what health reports.
---@param tpl string
---@param known string[]
---@return string[]
function M.unknown(tpl, known)
    local set = {}
    for _, name in ipairs(known) do
        set[name] = true
    end
    local out = {}
    for _, name in ipairs(M.names(tpl)) do
        if not set[name] then
            out[#out + 1] = name
        end
    end
    return out
end

return M
