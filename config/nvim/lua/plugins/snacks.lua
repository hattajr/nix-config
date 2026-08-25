-- Disable smooth-scroll animation. Holding `j`/`k` queued a scroll tween per
-- keystroke, which piled up and made navigation feel laggy. The indent guide
-- (snacks.indent) is left on.
-- return {
--   "folke/snacks.nvim",
--   opts = {
--     scroll = { enabled = false },
--     lazygit = {
--       -- blink's terminal ansi palette redefines green (color 2 / bright 10)
--       -- as blue, so lazygit's "added" diff lines render blue. Force git to
--       -- use truecolor hex values for diffs inside this lazygit session only.
--       env = {
--         GIT_CONFIG_PARAMETERS = "'color.diff.new=#a7da1e' 'color.diff.old=#e61f44'",
--       },
--     },
--   },
-- }


-- snacks' dashboard centers each header line INDIVIDUALLY based on that
-- line's own width. ASCII art whose lines have different widths (i.e. any
-- non-rectangular art) gets torn apart horizontally. Pad all lines to the
-- same display width so per-line centering yields identical offsets.
-- Done in Lua because hardcoded trailing spaces get stripped by editors.
local function pad_header(art)
  local lines = vim.split(art, "\n", { plain = true })
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  for i, line in ipairs(lines) do
    lines[i] = line .. (" "):rep(width - vim.fn.strdisplaywidth(line))
  end
  return table.concat(lines, "\n")
end

return {
  "folke/snacks.nvim",
  opts = {
    scroll = { enabled = false },
    lazygit = {
      env = {
        GIT_CONFIG_PARAMETERS = "'color.diff.new=#a7da1e' 'color.diff.old=#e61f44'",
      },
    },
    dashboard = {
      preset = {
        header = pad_header([[
                         ██████░██████░
                         ██████░██████░
                         ██████░██████░

                               ███████░      ███████████░
                               ███████░     ███████████████░
                               ███████░     █████████████████░
                               ███████░     █░       █████████░
                               ███████░                ███████░
                               ███████░                 ██████░
  ████░                        ███████░                 ██████░
██████░         ██████████████████████████████████████████████░
██████░         ██████████████████████████████████████████████░
███████░         ███████████████████░████████████████████████░
███████░            ███████░
████████░          ████████░
 █████████████████████████░
   █████████████████████░
     █████████████████░
]]),
      },
    },
  },
}
