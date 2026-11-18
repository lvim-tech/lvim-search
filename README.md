# lvim-search

Search that tells you where you are.

Neovim highlights every match of `/foo` identically, so a screen full of yellow says nothing about
which one the cursor is on, how many there are, or how far the next one is. `lvim-search` puts the
COMMAND that reaches each visible match beside it, and paints the nearest match in its own colour so
it stands out from the field.

It takes none of your keys. Not `n`, not `N`, not `*`, `#`, `/` or `?`. The plugin watches
`v:hlsearch` from a decoration provider, which is the one signal that sees every way a search can
begin or end — including `:nohlsearch`, an `<Esc>` out of incsearch, and a pattern set by `:s`.

```
alpha foo beta                                                      3N
nothing at all here
gamma foo delta foo                                                 2N
plain line          ← the cursor is here
epsilon foo zeta                                     n 4/5    3 •  1
another foo line                                                    2n
```

Every lens is the command that gets you there: ` 3N` means "type `3N`". The arrow says where the
match is; the key says what to press — they are not the same thing, because after a `?` search `n`
travels backwards. The nearest match adds how far into the set you are (`4/5`) and how many are left
each way — ` 3` behind the cursor, ` 1` ahead, joined by `•`.

## What it does

- **A command beside every visible match** — one lens per line, at the end of the line. ` 3n`
  means "type `3n`". Counting the presses yourself is exactly the arithmetic a counter should do
  for you.
- **A direction arrow** — `` for a match above the cursor, `` for one below. The key follows
  `v:searchforward` and swaps after a `?` search; the arrow does not, because it describes the
  buffer rather than the keyboard.
- **Where you are in the set** — the nearest match adds `4/5`, the one place an absolute reading
  answers a question the command does not.
- **The nearest match in its own colour** — but only when the cursor is not already on it, because
  Neovim's `CurSearch` already owns that case.
- **Nothing off screen** — the scan finds every match in the buffer; the renderer only decorates the
  lines in the window, so a hundred thousand matches cost the same as a dozen.
- **How much is left each way** — the nearest lens ends with ` 53 •  3`: fifty-three matches
  behind the cursor, three ahead. Countable from the window's edges instead with
  `remaining.from = "window"`, or off entirely.
- **Every window** — a split is decorated too, counted from its own cursor, without waiting to be
  focused.
- **A count before you commit** — the lenses appear while you are still typing `/foo`, counting the
  partial pattern. The numbers are the ones you will have after `<CR>`, so committing moves nothing.
- **A quickfix export** — `:LvimSearchExport` turns the current search into a navigable list, over
  this buffer or every buffer you have open, built from the same matches you can see rather than a
  second `:vimgrep` that might disagree.
- **A counter for your statusline** — `require("lvim-search").status()`, plus a
  `User LvimSearchStatus` event fired only when the value actually changes.
- **`calm_down`** — optionally end the search as soon as the cursor leaves the match it was on.

## Requirements

- Neovim 0.12 or newer (`matchbufline()`, decoration providers)
- `lvim-utils`
- `'hlsearch'` on — without it `v:hlsearch` never becomes 1 and nothing appears; `:checkhealth
  lvim-search` says so in as many words.

## Installation

With **lvim-installer**:

```lua
require("lvim-installer").install({
    "lvim-tech/lvim-utils",
    "lvim-tech/lvim-search",
})
```

Or with Neovim's native `vim.pack`:

```lua
vim.pack.add({
    "https://github.com/lvim-tech/lvim-utils",
    "https://github.com/lvim-tech/lvim-search",
})
```

Then:

```lua
require("lvim-search").setup({})
```

## Configuration

`setup()` merges into the live config, so anything left out keeps the value below.

```lua
require("lvim-search").setup({
    -- Master switch. With this off nothing is scanned and nothing is drawn.
    enabled = true,
    -- Appear and disappear with `v:hlsearch`, taking no mappings. With this off the lenses only
    -- show after :LvimSearchToggle.
    auto_start = true,
    -- Clear the search as soon as the cursor leaves the match it was on.
    calm_down = false,
    -- Draw ONLY the nearest lens, not one per visible match.
    nearest_only = false,
    -- Milliseconds between cursor-driven repaints. The first move of a burst repaints at once; only
    -- the storm behind it is thinned.
    throttle = 120,
    -- "visible" decorates every window in the tab page, "current" only the focused one. A buffer
    -- shown in TWO windows is counted for the window you are in: one set of extmarks cannot
    -- describe two cursors.
    windows = "visible",
    -- How "nearest" is measured. "buffer" counts buffer lines and is free; "screen" counts the rows
    -- you can actually see -- exact about folds and wrapping, at one nvim_win_text_height() call per
    -- comparison. They differ only when a fold or a wrapped line sits between the two candidates.
    nearest_by = "buffer",

    -- Say, in the NEAREST lens, how many matches remain in each direction.
    remaining = {
        enabled = true,
        -- Measured from the CURSOR (how many are left that way) or from the edges of the WINDOW
        -- (how many are not on screen -- which falls to zero while matches are still visible).
        from = "cursor",
        -- Nerd Font glyphs, one cell each. Deliberately not the plain arrows the indicator uses:
        -- a double angle reads as "and more, that way".
        above = "",
        below = "",
        -- The body of each side, separately: {glyph} and {count} in whichever order you like, and
        -- not necessarily the same on both. Mirrored by default, so both icons sit on the outside:
        -- icon count  ·  count icon.
        format = { above = "{glyph} {count}", below = "{count} {glyph}" },
        -- Around the PAIR, exactly like `lens.wrap`; both "" for bare text.
        wrap = { left = " ", right = " " },
        -- BETWEEN the two counts. Its own option because the wrap cannot express it: padding on the
        -- outside of each side would meet at the junction and double.
        sep = " 󰧟 ",
    },

    -- Count the pattern WHILE it is being typed, before <CR>.
    preview = {
        enabled = true,
        -- Do not scan anything shorter. One character matches most of a large file and the answer
        -- changes completely with the next keystroke.
        min_chars = 2,
        -- Push the screen update from the cmdline autocmd. Without it nothing appears until <CR>,
        -- because Neovim's own incsearch redraw has already happened by then.
        redraw = true,
        -- Milliseconds a preview scan may take before the pattern is judged too broad to preview.
        -- It then waits for a longer one -- which is cheaper, so this self-corrects as you type.
        budget = 50,
    },

    -- Buffers that are never decorated. A search is a fact about the DOCUMENT; the editor's own
    -- chrome (the cmdline zone, a picker, a completion menu, a framed panel) holds text that may
    -- contain the pattern but nothing the reader can jump to.
    ignore = {
        buftype = { "terminal", "prompt", "quickfix" },
        filetype = { "lvim-ui-frame", "lvim-utils-ui", "lvim-ui-menu" },
    },

    scan = {
        -- Above this many matches the scan stops and the plugin degrades rather than going silent.
        max_matches = 100000,
        -- What a capped buffer still shows: "count" keeps the nearest counter, "off" shows nothing.
        degrade = "count",
        -- Allow the slower bounded walk for patterns that can cross lines (`\n`, `\_.`).
        multiline = true,
        -- Milliseconds that walk may take, per scan.
        multiline_timeout = 100,
        -- How many buffers keep their match list (LRU).
        cache_buffers = 8,
    },

    lens = {
        -- Extmark priority for the lens text.
        priority = 100,
        -- "combine" keeps the buffer's own syntax visible under the lens.
        hl_mode = "combine",
        -- Spacer between the line's text and the lens.
        gap = " ",
        -- The nearest lens body. Every format string here uses NAMED placeholders, so their order
        -- is yours to change: "{total} of {current}" works as well as "{current}/{total}".
        nearest_format = "{current}/{total}",
        -- Every other lens body: its indicator ("2n", "3N").
        other_format = "{indicator}",
        -- Around a lens; both "" for bare text.
        wrap = { left = " ", right = " " },
        indicator = {
            -- Show how to REACH a match, not just where it sits in the order.
            enabled = true,
            -- Arrow for a match above the cursor, and below. Both "" to drop the arrows.
            up = " ",
            down = " ",
            -- The key that travels down the buffer, and up. Which is which follows
            -- v:searchforward automatically -- after `?` they swap, and the lens swaps with them.
            forward = "n",
            backward = "N",
            -- {arrow}, {count}, {key} -- in any order. The count is "" when a single press does
            -- it, so the indicator reads as the exact command to type: "2n", "N".
            format = "{arrow}{count}{key}",
        },
        -- Where a lens goes when the line is too long for it to sit after the text:
        -- "right_align", "eol_right_align" or "hide".
        overflow = "right_align",
        -- Full override. Return extmark chunks, or nil to fall back to the built-in body for that
        -- match. ctx = { buf, index, current, total, nearest, forward, rel, lnum, col }.
        format = nil,
    },

    nearest_hl = {
        -- Paint the nearest match itself, not just its lens.
        enabled = true,
        -- Only when the cursor is NOT on it — `CurSearch` already owns that case.
        only_off_match = true,
        -- On the matchadd() scale, where 'hlsearch' is 0 and other matches default to 10.
        priority = 20,
    },

    counter = {
        -- Fire `User LvimSearchStatus` when the counter changes.
        publish = true,
    },

    qf = {
        -- Title of the exported list: {pattern}.
        title = "Search 󰅂 {pattern}",
        -- …and when the export swept several buffers: {pattern}, {buffers}.
        title_scoped = "Search 󰅂 {pattern} ({buffers} buffers)",
    },

    -- Where an export goes instead of the quickfix list. Same shape Neovim's own LSP handlers use:
    -- on_list({ items = …, title = …, context = { pattern = …, capped = … } }).
    on_list = nil,

    highlights = {
        -- Palette colour NAMES (lvim-utils.colors keys), never hex literals, so the groups track
        -- the theme. `tint` is the blend toward the background.
        lens = { accent = "yellow", tint = 0.2 },
        lens_nearest = { accent = "blue", tint = 0.4, bold = true },
        nearest_match = { accent = "orange", tint = 0.4 },
        -- Its own accent inside the nearest lens, so the counts read as a different fact from
        -- the counter beside them. `bg = false` is accepted on any of these and paints the accent
        -- as a foreground only, with no tinted cell behind it.
        remaining = { accent = "yellow", tint = 0.4 },
    },

    debug = false,
})
```

## Commands

| Command              | What it does                                                |
| -------------------- | ----------------------------------------------------------- |
| `:LvimSearchToggle`  | Show or hide the lenses without changing the search          |
| `:LvimSearchRefresh` | Repaint now, ignoring the throttle                           |
| `:LvimSearchExport`  | Send every match of the current search to the quickfix list  |
| `:LvimSearchExport all`  | …across every loaded, listed buffer                      |
| `:LvimSearchExport args` | …across the argument list                                |

## API

```lua
local search = require("lvim-search")

search.start() -- begin keeping the lenses current
search.stop() -- stop, leaving nothing behind
search.toggle()
search.refresh() -- repaint now
search.export() -- to the quickfix list, or to config.on_list

local status = search.status() -- { pattern, current, total, capped, on_match, forward } or nil
local state = search.state -- "IDLE" or "ACTIVE"
```

## In a statusline

Poll it:

```lua
local function search_count()
    local s = require("lvim-search").status()
    return s and ("%d/%d"):format(s.current, s.total) or ""
end
```

…or listen, and repaint only when it changes:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "LvimSearchStatus",
    callback = function(ev)
        vim.g.search_count = ev.data.total and ("%d/%d"):format(ev.data.current, ev.data.total) or ""
        vim.cmd("redrawstatus")
    end,
})
```

## Highlight groups

| Group                    | What it paints                                       |
| ------------------------ | ---------------------------------------------------- |
| `LvimSearchLens`         | An ordinary lens                                     |
| `LvimSearchLensNearest`  | The lens of the nearest match                        |
| `LvimSearchNearest`      | The nearest match itself, above `Search`             |
| `LvimSearchRemaining`    | The counts of matches left in each direction         |

All four are derived from the lvim-utils palette and re-derived on a colorscheme change. Override
them through `highlights` in `setup()` rather than with `:highlight`, so they keep tracking the
theme.

## Health

```vim
:checkhealth lvim-search
```

Reports the environment, the live state, every configurable format and glyph, and whether the
accents name real palette colours.

## Icons

Every icon this plugin draws is a Nerd Font glyph. When [lvim-icons](https://github.com/lvim-tech/lvim-icons)
runs in `mode = "material"` and the terminal shows kitty unicode placeholders, the plugin's own UI glyphs are
drawn as images of those same glyphs, in their own colours and with their columns kept; in `nerd` and `mix`
they stay text. There is nothing to set here: the mode is lvim-icons' (`lvim-utils.icons.ui_text` does the
work).

## License

BSD-3-Clause
