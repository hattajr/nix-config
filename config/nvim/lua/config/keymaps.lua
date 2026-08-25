-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- tmux copy-mode behavior inside Neovim: releasing a mouse drag yanks the visual
-- selection straight to the system clipboard (via OSC 52) and exits Visual mode,
-- so the highlight clears automatically. No need to press y.
vim.keymap.set("x", "<LeftRelease>", '"+y', { desc = "Copy mouse selection to clipboard" })
