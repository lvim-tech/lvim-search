-- lvim-search.health: `:checkhealth lvim-search`.
--
-- The checks are the ones that explain an actual symptom. Chief among them: with `'hlsearch'` off,
-- `v:hlsearch` never becomes 1, the decoration provider never sees a search begin, and the plugin
-- appears completely dead while every one of its parts works — so that option is checked FIRST and
-- reported as an error, not a note.
--
-- The rest verify the things a user can misconfigure into silence: a format string with the wrong
-- number of placeholders, an accent that is not a palette colour, a glyph that occupies two cells
-- and pushes every lens out of alignment, a cap of zero.
--
---@module "lvim-search.health"

local config = require("lvim-search.config")
local template = require("lvim-search.template")

local fn = vim.fn
local health = vim.health

local M = {}

--- Report on one format template.
---
--- Checks the NAMES it uses, not how many placeholders it has: an unknown `{name}` renders verbatim
--- on screen, which is visible but puzzling, and a check that can say "you wrote {cout}, I know
--- {count}" turns a puzzle into a one-word fix.
---@param label string
---@param value any
---@param known string[]
---@return nil
local function check_template(label, value, known)
    if type(value) ~= "string" then
        health.error(("%s must be a string, got %s"):format(label, type(value)))
        return
    end
    local unknown = template.unknown(value, known)
    if #unknown == 0 then
        health.ok(("%s = %q"):format(label, value))
    else
        health.warn(
            ("%s = %q uses unknown placeholder(s): %s"):format(label, value, table.concat(unknown, ", ")),
            { "Known here: " .. table.concat(known, ", ") .. ". Unknown ones are drawn as written." }
        )
    end
end

--- Report on one configurable glyph.
---
--- One or two cells pass: a glyph with a trailing space is a deliberate choice about spacing, not a
--- defect, and warning about it would be telling the user their own config is wrong. Wider than that
--- is a genuine problem — it means a double-width character where a single one was assumed.
---@param label string
---@param value any
---@return nil
local function check_glyph(label, value)
    if type(value) ~= "string" then
        health.error(("%s must be a string, got %s"):format(label, type(value)))
        return
    end
    if value == "" then
        health.ok(("%s is empty (nothing drawn)"):format(label))
        return
    end
    local cells = fn.strdisplaywidth(value)
    if cells <= 2 then
        health.ok(("%s = %q (%d cell%s)"):format(label, value, cells, cells == 1 and "" or "s"))
    else
        health.warn(("%s = %q occupies %d cells — the lens column will not line up"):format(label, value, cells))
    end
end

--- Run the checks.
---@return nil
function M.check()
    health.start("lvim-search")

    -- ── the environment ─────────────────────────────────────────────────────
    if fn.has("nvim-0.12") == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.error("Neovim >= 0.12 is required (the lvim-tech set targets 0.12; lvim-utils requires it)")
    end

    if fn.exists("*matchbufline") == 1 then
        health.ok("matchbufline() available — the fast scanner is in use")
    else
        health.error("matchbufline() is missing; every scan would fall back to the bounded walk")
    end

    if vim.o.hlsearch then
        health.ok("'hlsearch' is on")
    else
        health.error("'hlsearch' is OFF — nothing will ever be shown", {
            "The plugin starts when v:hlsearch becomes 1, which only happens with 'hlsearch' set.",
            "Add `vim.o.hlsearch = true` to your options.",
        })
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    if ok_utils then
        health.ok("lvim-utils found")
    else
        health.error("lvim-utils is not on the runtimepath (setup() cannot merge options)")
    end

    -- ── the live state ──────────────────────────────────────────────────────
    health.start("lvim-search: state")
    local search = require("lvim-search")
    health.info("state: " .. search.state)
    if config.enabled then
        health.ok("enabled")
    else
        health.warn("`enabled = false` — nothing is drawn")
    end
    if config.auto_start then
        health.ok("auto_start: lenses appear on their own, no mappings are taken")
    else
        health.warn("`auto_start = false` — nothing appears until :LvimSearchToggle")
    end
    local status = search.status()
    if status then
        health.info(("counting %q: %d/%d"):format(status.pattern, status.current, status.total))
    end

    -- ── the configuration ───────────────────────────────────────────────────
    health.start("lvim-search: configuration")

    if type(config.throttle) == "number" and config.throttle >= 0 then
        health.ok(("throttle = %dms"):format(config.throttle))
    else
        health.error(("throttle must be a non-negative number, got %s"):format(tostring(config.throttle)))
    end

    if type(config.scan.max_matches) == "number" and config.scan.max_matches > 0 then
        health.ok(("scan.max_matches = %d"):format(config.scan.max_matches))
    else
        health.error("scan.max_matches must be a positive number")
    end

    if config.scan.degrade == "count" or config.scan.degrade == "off" then
        health.ok(("scan.degrade = %q"):format(config.scan.degrade))
    else
        health.error(('scan.degrade must be "count" or "off", got %s'):format(tostring(config.scan.degrade)))
    end

    local overflow = { right_align = true, eol_right_align = true, hide = true }
    if overflow[config.lens.overflow] then
        health.ok(("lens.overflow = %q"):format(config.lens.overflow))
    else
        health.error(
            ('lens.overflow must be "right_align", "eol_right_align" or "hide", got %s'):format(
                tostring(config.lens.overflow)
            )
        )
    end

    check_template("lens.nearest_format", config.lens.nearest_format, { "current", "total" })
    check_template("lens.other_format", config.lens.other_format, { "indicator" })
    check_template("lens.indicator.format", config.lens.indicator.format, { "arrow", "count", "key" })
    check_template("qf.title", config.qf.title, { "pattern" })

    -- The arrows may be "" on purpose (arrows off); the KEYS may not, or the lens would stop
    -- naming a command and become an unexplained number.
    check_glyph("lens.indicator.up", config.lens.indicator.up)
    check_glyph("lens.indicator.down", config.lens.indicator.down)
    for _, key in ipairs({ "forward", "backward" }) do
        local value = config.lens.indicator[key]
        if type(value) == "string" and value ~= "" then
            health.ok(("lens.indicator.%s = %q"):format(key, value))
        else
            health.error(("lens.indicator.%s must be a non-empty key name"):format(key))
        end
    end
    if config.lens.indicator.forward == config.lens.indicator.backward then
        health.warn("lens.indicator.forward and .backward are the same key — direction is unreadable")
    end

    if config.nearest_hl.enabled then
        if type(config.nearest_hl.priority) == "number" and config.nearest_hl.priority > 10 then
            health.ok(
                ("nearest_hl.priority = %d (above 'hlsearch' and matchadd's default)"):format(
                    config.nearest_hl.priority
                )
            )
        else
            health.warn(("nearest_hl.priority = %s"):format(tostring(config.nearest_hl.priority)), {
                "This is the matchadd() scale: 'hlsearch' is 0 and other matches default to 10.",
                "Below 11 the emphasis may not be visible.",
            })
        end
    end

    if config.windows == "visible" or config.windows == "current" then
        health.ok(("windows = %q"):format(config.windows))
    else
        health.error(('windows must be "visible" or "current", got %s'):format(tostring(config.windows)))
    end

    if config.nearest_by == "buffer" or config.nearest_by == "screen" then
        health.ok(("nearest_by = %q"):format(config.nearest_by))
    else
        health.error(('nearest_by must be "buffer" or "screen", got %s'):format(tostring(config.nearest_by)))
    end

    if config.remaining.enabled then
        if config.remaining.from == "cursor" or config.remaining.from == "window" then
            health.ok(("remaining.from = %q"):format(config.remaining.from))
        else
            health.error(
                ('remaining.from must be "cursor" or "window", got %s'):format(tostring(config.remaining.from))
            )
        end
        check_glyph("remaining.above", config.remaining.above)
        check_glyph("remaining.below", config.remaining.below)
        if type(config.remaining.format) ~= "table" then
            health.error("remaining.format must be a table of two templates ({ above = …, below = … })")
        else
            for _, side in ipairs({ "above", "below" }) do
                check_template("remaining.format." .. side, config.remaining.format[side], { "glyph", "count" })
            end
        end
        local w = config.remaining.wrap
        if type(w) ~= "table" or type(w.left) ~= "string" or type(w.right) ~= "string" then
            health.error("remaining.wrap must be a table of two strings ({ left = …, right = … })")
        else
            health.ok(("remaining.wrap = %q … %q"):format(w.left, w.right))
        end
        if config.remaining.above == "" and config.remaining.below == "" then
            health.warn("both remaining glyphs are empty — nothing will say how much is left either way")
        end
    else
        health.info("remaining counts are off — nothing says how many matches are left in each direction")
    end

    if config.preview.enabled then
        if type(config.preview.min_chars) == "number" and config.preview.min_chars >= 1 then
            health.ok(("preview.min_chars = %d"):format(config.preview.min_chars))
        else
            health.error("preview.min_chars must be at least 1")
        end
        if type(config.preview.budget) == "number" and config.preview.budget > 0 then
            health.ok(("preview.budget = %dms"):format(config.preview.budget))
        else
            health.error("preview.budget must be a positive number of milliseconds")
        end
        if not config.preview.redraw then
            health.warn("`preview.redraw = false` — the count will not appear until <CR>", {
                "Neovim's own incsearch redraw has already happened when the preview is painted.",
            })
        end
        if not vim.o.incsearch then
            health.info("'incsearch' is off; the preview still counts, there is just no match preview under it")
        end
    else
        health.info("preview is off — patterns are only counted once committed")
    end

    check_template("qf.title_scoped", config.qf.title_scoped, { "pattern", "buffers" })

    if type(config.lens.format) == "function" then
        health.info("lens.format is set — it overrides every built-in lens body")
    end
    if type(config.on_list) == "function" then
        health.info("on_list is set — :LvimSearchExport bypasses the quickfix list")
    end

    -- ── the palette ─────────────────────────────────────────────────────────
    health.start("lvim-search: colours")
    local ok_colors, colors = pcall(require, "lvim-utils.colors")
    if not ok_colors or type(colors) ~= "table" then
        health.error("lvim-utils.colors is unavailable; the groups cannot be derived from the palette")
        return
    end
    for key, spec in pairs(config.highlights) do
        if type(spec.accent) ~= "string" or colors[spec.accent] == nil then
            health.error(("highlights.%s.accent = %s is not a palette colour"):format(key, tostring(spec.accent)), {
                "Use a key of lvim-utils.colors (blue, yellow, orange, red, green, …), never a hex literal.",
            })
        elseif type(spec.tint) ~= "number" or spec.tint < 0 or spec.tint > 1 then
            health.error(("highlights.%s.tint must be between 0 and 1, got %s"):format(key, tostring(spec.tint)))
        else
            health.ok(("highlights.%s = %s at %.2f"):format(key, spec.accent, spec.tint))
        end
    end
end

return M
