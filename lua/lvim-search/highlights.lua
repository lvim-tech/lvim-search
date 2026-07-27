-- lvim-search.highlights: the three groups the plugin paints with, self-themed from the shared
-- lvim-utils palette through a bound factory — so they follow a colorscheme change or a live palette
-- retune without this plugin knowing anything happened.
--
-- Each group follows the set-wide tint canon: a coloured cell is its OWN accent laid over the
-- surface it sits on. Here that surface is the editor background, because a lens is virtual text on
-- a normal line and the emphasis is painted over real buffer text.
--
-- The accents and tints come from the LIVE config, so a second `setup()` (or a control-center
-- retune) must rebuild the groups rather than no-op — the bound factory alone only re-runs on a
-- palette change, which is why `M.setup()` re-registers with force when it has run before.
--
---@module "lvim-search.highlights"

local hl = require("lvim-utils.highlight")
local config = require("lvim-search.config")

local M = {}

---@type boolean  the factory is already bound
local bound = false

---@type table<string, string>  config key → highlight group name
local NAMES = {
    lens = "LvimSearchLens",
    lens_nearest = "LvimSearchLensNearest",
    nearest_match = "LvimSearchNearest",
    remaining = "LvimSearchRemaining",
}

--- Build every group from the live palette and the live config.
---@param c table?  the live palette (defaults to lvim-utils.colors)
---@return table<string, table>
local function build(c)
    c = c or require("lvim-utils.colors")
    local groups = {}
    for key, name in pairs(NAMES) do
        local spec = config.highlights[key] or {}
        local color = c[spec.accent] or c.fg
        groups[name] = {
            fg = color,
            -- `bg = false` means foreground only. The key is omitted rather than set to a value:
            -- a group with no bg lets whatever is behind it show through, which is what a glyph in
            -- the sign column wants.
            bg = spec.bg ~= false and hl.blend(color, c.bg, spec.tint or 0.2) or nil,
            bold = spec.bold or false,
        }
    end
    return groups
end

--- Bind the palette factory. Idempotent, and a repeat call re-derives from the current config.
---@return nil
function M.setup()
    if bound then
        hl.register(build(), true)
        return
    end
    bound = true
    hl.bind(build)
end

return M
