return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
  opts = {},
  keys = {
    -- <leader>gd deliberately overrides LazyVim's Snacks git-diff picker.
    -- gH (not gh): <leader>gh is LazyVim's gitsigns "hunks" group prefix.
    { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diffview Open" },
    { "<leader>gH", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview File History" },
    { "<leader>gc", "<cmd>DiffviewClose<cr>", desc = "Diffview Close" },
  },
}
