-- lvim-search.config: the LIVE config — setup() merges user options into this table IN PLACE
-- (lvim-utils.utils.merge), so every `require("lvim-search.config")` reader sees the effective
-- values and there is no second copy.
--
-- Every glyph, timeout, format, priority and colour is an option: the plugin decorates the user's
-- own buffers, and a decorator with hardcoded taste is one the user cannot live with.
--
---@module "lvim-search.config"

---@class LvimSearchScanConfig
---@field max_matches integer  scanner cap; above it the plugin DEGRADES rather than going silent
---@field degrade "count"|"off"  what a capped buffer still shows: a nearest counter, or nothing
---@field multiline boolean    allow the bounded `searchpos` fallback for patterns that can cross lines
---@field multiline_timeout integer  ms budget for that fallback, per scan
---@field cache_buffers integer  how many buffers keep their match list (LRU)

---@class LvimSearchIndicatorConfig
---@field enabled boolean      show how to reach a match, not just where it sits in the order
---@field up string            arrow for a match ABOVE the cursor (Nerd Font, one cell) …
---@field down string          … and for one below. Both "" to drop the arrows entirely
---@field forward string       the key that travels DOWN the buffer …
---@field backward string      … and up. Which is which follows `v:searchforward` automatically —
---   after `?` the keys swap, and the indicator swaps with them
---@field format string        `{arrow}`, `{count}`, `{key}` — in any order you like, which is the
---   point of naming them: `"{count}{key}{arrow}"` puts the glyph last. The count is "" when a
---   single press does it, so the indicator reads as the exact command to type: "2n", "N"

---@class LvimSearchLensConfig
---@field priority integer     extmark priority for the lens text
---@field hl_mode string       "combine" keeps the buffer's own syntax visible under the lens
---@field gap string           spacer between the line's text and the lens
---@field nearest_format string  the nearest lens body: `{current}`, `{total}`
---@field other_format string  every other lens body: `{indicator}` ("2n", "3N")
---@field wrap { left: string, right: string }  brackets around a lens; both "" for bare text
---@field indicator LvimSearchIndicatorConfig
---@field overflow "right_align"|"eol_right_align"|"hide"  where the nearest lens goes when the
---   line is too long for it to sit after the text
---@field format? fun(ctx: table): table[]|nil  full override: return extmark chunks, or nil to fall
---   back to the built-in formatting for that match

---@class LvimSearchNearestHlConfig
---@field enabled boolean
---@field only_off_match boolean  paint only when the cursor is NOT on the match — Neovim's own
---   `CurSearch` already owns the on-the-match case, and two highlights fighting over it is worse
---   than one
---@field priority integer     on the `matchadd()` scale, NOT the extmark one: 'hlsearch' sits at 0
---   there and the default `matchadd()` priority is 10, so anything above 10 wins both

---@class LvimSearchHighlightSpec
---@field accent string        a palette colour NAME (lvim-utils.colors key), never a hex literal
---@field tint number          blend factor toward the background (the set-wide tint canon)
---@field bg boolean?          false paints the accent as a FOREGROUND only, with no tinted cell
---   behind it — for a glyph that sits in the sign column, where a coloured block reads as a
---   smudge rather than a mark
---@field bold boolean?

---@class LvimSearchPreviewConfig
---@field enabled boolean      count the pattern WHILE it is being typed, before `<CR>`
---@field min_chars integer    do not scan a pattern shorter than this. One character matches most
---   of a large file, and the answer changes completely with the next keystroke
---@field redraw boolean       push the screen update from the cmdline autocmd. Needed for the
---   lenses to appear at all while typing, since Neovim's own incsearch redraw has already
---   happened by the time this runs
---@field budget integer       ms a preview scan may take before the pattern is judged too broad to
---   preview. It then waits for a longer one — which is cheaper, so this self-corrects as you type

---@class LvimSearchRemainingConfig
---@field enabled boolean      say, in the nearest lens, how many matches remain in each direction
---@field from "cursor"|"window"  measured from the CURSOR (how many are left that way — what an
---   arrow beside a counter promises) or from the edges of the WINDOW (how many are not on screen —
---   not derivable from anything else, but it falls to zero while matches are still visible)
---@field above string         the glyph for what is BEHIND the cursor (Nerd Font, one cell) …
---@field below string         … and ahead of it. Either "" to drop that side
---@field format { above: string, below: string }  the body of each side, separately: `{glyph}` and
---   `{count}` in whichever order you like, and not necessarily the same order on both — the two
---   sides are mirror images, so `{count}{glyph}` above and `{glyph}{count}` below puts the icon on
---   the outside of each
---@field wrap { left: string, right: string }  around the PAIR, exactly like `lens.wrap`; both ""
---   for bare text
---@field sep string           between the two counts when both are shown. Separate from `wrap`
---   because outer padding cannot express it: applied per side it would double at the junction

---@class LvimSearchIgnoreConfig
---@field buftype string[]     buffer types never decorated
---@field filetype string[]    file types never decorated

---@class LvimSearchConfig
---@field enabled boolean      master switch
---@field auto_start boolean   start and stop purely from `v:hlsearch` — no mappings at all
---@field calm_down boolean    clear the search when the cursor leaves the nearest match
---@field nearest_only boolean render ONLY the nearest lens
---@field throttle integer     ms between cursor-driven refreshes
---@field windows "visible"|"current"  decorate every window in the tab page, or only the one the
---   cursor is in. A buffer shown in TWO windows is decorated for the window you are in, since one
---   set of extmarks cannot describe two cursors
---@field nearest_by "buffer"|"screen"  measure "nearest" in buffer lines, or in rows the reader can
---   actually see. Screen distance is exact about folds and wrapping and costs a
---   `nvim_win_text_height` call per comparison; buffer distance is free and differs only when a
---   fold or a wrapped line sits between the two candidates
---@field ignore LvimSearchIgnoreConfig
---@field remaining LvimSearchRemainingConfig
---@field preview LvimSearchPreviewConfig
---@field scan LvimSearchScanConfig
---@field lens LvimSearchLensConfig
---@field nearest_hl LvimSearchNearestHlConfig
---@field counter { publish: boolean }  fire `User LvimSearchStatus` so a statusline can read it
---@field qf { title: string, title_scoped: string }  `{pattern}`, and `{buffers}` when scoped
---@field on_list? fun(arg: { items: table[], title: string, context: table })  where an export goes
---   instead of the quickfix list. Same shape Neovim's own LSP handlers use, so a picker that
---   already accepts `on_list` accepts this one unchanged.
---@field highlights table<string, LvimSearchHighlightSpec>
---@field debug boolean
local M = {
    enabled = true,
    -- The whole point of the modern design: `v:hlsearch` flips to 1 for `/`, `?`, `*`, `#`, `g*`,
    -- `g#` and a pattern set by `:s`, and the decoration provider sees that on the next redraw. So
    -- the plugin needs no mappings of its own — nothing of the user's is taken over or shadowed.
    auto_start = true,
    -- Off by default deliberately: clearing someone's search because their cursor wandered is a
    -- strong opinion, and one they should choose rather than discover.
    calm_down = false,
    nearest_only = false,
    -- Cursor-driven refreshes are throttled rather than debounced: the first move of a burst should
    -- repaint immediately, and only the storm behind it is thinned.
    throttle = 120,
    -- Every window of the tab page, so a split does not go unlabelled until you focus it.
    windows = "visible",
    -- Buffer distance by default: it is free, and it differs from what the eye sees only when a fold
    -- or a wrapped line sits between the two candidate matches.
    nearest_by = "buffer",
    -- Only the buffer types where a search counter would be meaningless. `quickfix` is here because
    -- a results list is not text you are searching — an export whose pattern also matches its own
    -- rows would label them, which is noise nobody asked for. `nofile` is NOT here: many perfectly
    -- searchable buffers (a scratch, a preview) carry it, and a plugin panel that does not want
    -- lenses can name its own filetype below.
    -- THE BLACKLIST. A search is a fact about the DOCUMENT, and the set's own chrome is not one:
    -- the cmdline zone, a picker, a completion menu and a framed panel all hold text that happens
    -- to contain the pattern, and painting a match there marks something the reader cannot jump to
    -- (reported from a screenshot: the typed `:LvimForg` lit up inside the command line). Both
    -- lists are plain config — a surface this plugin has never heard of is one line to exclude.
    ignore = {
        buftype = { "terminal", "prompt", "quickfix" },
        filetype = {
            -- lvim-ui: the framed container / hide-cursor panels, the generic surface buffer, and
            -- the completion menu float.
            "lvim-ui-frame",
            "lvim-utils-ui",
            "lvim-ui-menu",
        },
    },
    -- What the viewport hides is exactly what the reader cannot judge for themselves — so the
    -- nearest lens carries it. NOT the sign column: a sign belongs to a LINE and is drawn on that
    -- line's first screen row, so with 'wrap' on it lands above the bottom of the window whenever
    -- the last row is a continuation (measured), and it moves a row per scroll step. This is a fact
    -- about the WINDOW, and the lens is the one place already dedicated to saying such things.
    -- How many matches lie behind the cursor and ahead of it, said in the nearest lens.
    --
    -- Counted from the CURSOR, not from the edges of the window: an arrow beside a counter reads as
    -- "this many that way", and a viewport-relative count contradicts that — it drops to zero while
    -- matches are plainly visible below, just because they have not left the screen yet.
    remaining = {
        enabled = true,
        from = "cursor",
        -- nf-fa-angle_double_up / _down (U+F102 / U+F103), one cell each. Deliberately NOT the
        -- plain arrows the indicator uses: side by side, two identical arrows would mean two
        -- different things, while a double angle reads as "and more, that way".
        above = "",
        below = "",
        -- Mirrored around the separator, so both glyphs sit on the OUTSIDE: icon, count · count,
        -- icon. That is what the two templates being separate is for.
        format = { above = "{glyph} {count}", below = "{count} {glyph}" },
        wrap = { left = " ", right = " " },
        -- BETWEEN the two counts, when both are shown. Its own option because the wrap cannot do
        -- this job: padding on the outside of each side would meet at the junction and put the two
        -- values twice as far apart as either edge. A bullet (U+2022, verified one cell) — the
        -- set-wide 󰅂 separator is a POINTER, and these two counts point opposite ways.
        sep = " • ",
    },
    -- While a search is being typed, the plugin deliberately ignores `v:hlsearch` — 'incsearch'
    -- toggles it per keystroke and swaps `@/` to the partial pattern, so it says nothing true. The
    -- cmdline text itself does: read it directly and the count is right before <CR> is pressed.
    preview = {
        enabled = true,
        min_chars = 2,
        redraw = true,
        -- Measured: a selective pattern over 200k lines scans in ~42ms, a single common letter in
        -- ~770ms — the cost follows the number of MATCHES, not the size of the file. A preview must
        -- never be the reason typing stutters, so one that overruns steps aside until the pattern
        -- is longer.
        budget = 50,
    },
    scan = {
        max_matches = 100000,
        degrade = "count",
        multiline = true,
        multiline_timeout = 100,
        cache_buffers = 8,
    },
    lens = {
        priority = 100,
        hl_mode = "combine",
        gap = " ",
        nearest_format = "{current}/{total}",
        -- Every other lens body is its INDICATOR — how to GET there, not where it sits in the
        -- order. `[3n]` on a line means exactly that: type `3n`. An absolute index would name the
        -- match and leave the reader to count the presses themselves.
        other_format = "{indicator}",
        wrap = { left = " ", right = " " },
        indicator = {
            enabled = true,
            -- nf-fa-arrow_up / nf-fa-arrow_down (U+F062 / U+F063), both a single cell.
            up = " ",
            down = " ",
            forward = "n",
            backward = "N",
            format = "{arrow}{count}{key}",
        },
        overflow = "right_align",
        format = nil,
    },
    nearest_hl = {
        enabled = true,
        only_off_match = true,
        priority = 20,
    },
    counter = { publish = true },
    -- `󰅂` per the separator canon.
    qf = {
        title = "Search 󰅂 {pattern}",
        -- A sweep across buffers says how many it actually read, so a short list is never mistaken
        -- for "that is all there is".
        title_scoped = "Search 󰅂 {pattern} ({buffers} buffers)",
    },
    on_list = nil,
    highlights = {
        lens = { accent = "yellow", tint = 0.2 },
        lens_nearest = { accent = "blue", tint = 0.4, bold = true },
        nearest_match = { accent = "orange", tint = 0.4 },
        -- Its own accent inside the nearest lens, so the counts read as a different fact from the
        -- counter beside them.
        remaining = { accent = "yellow", tint = 0.4 },
    },
    debug = false,
}

return M
