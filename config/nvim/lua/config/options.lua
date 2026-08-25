-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Use ty (Astral's Rust type checker/LSP) as the Python LSP instead of pyright.
-- The lazyvim.plugins.extras.lang.python extra reads this at load time and
-- disables pyright/basedpyright accordingly. Must be set here (before lazy startup),
-- not in a plugin spec. ty install / mason=false is handled in plugins/ty.lua.
vim.g.lazyvim_python_lsp = "ty"

-- Route the system clipboard (+/* registers) through OSC 52 so yanks reach the
-- local terminal's clipboard over ssh/mosh+tmux (same pipe tmux copy-mode uses).
-- Without this, Neovim would prefer a remote xclip/xsel/wl-copy and copies would
-- silently write to the server's (nonexistent) X clipboard. Paste reads back from
-- the register instead of querying the terminal, which mosh/many terminals block.
local osc52 = require("vim.ui.clipboard.osc52")
local function paste_from_reg(reg)
  return function()
    local text = vim.fn.getreg(reg)
    return vim.split(text, "\n", { plain = true })
  end
end
vim.g.clipboard = {
  name = "OSC 52",
  copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
  paste = { ["+"] = paste_from_reg("+"), ["*"] = paste_from_reg("*") },
}

-- LazyVim disables clipboard sync under SSH (opt.clipboard = SSH_TTY and "" or
-- "unnamedplus"), so plain `y` never hits the + register and the OSC 52 provider
-- above is bypassed. Force unnamedplus on so every yank routes through OSC 52.
vim.opt.clipboard = "unnamedplus"
