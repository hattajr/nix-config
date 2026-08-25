-- Try out ty (Astral's Rust-based Python type checker/LSP).
-- Selection of ty over pyright is driven by vim.g.lazyvim_python_lsp = "ty" in
-- config/options.lua, which lets the LazyVim python extra disable pyright for us.
-- ty is a standalone binary (uv tool install ty), not a Mason package, so
-- mason = false stops LazyVim from trying to fetch it from a registry it isn't in.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ty = { mason = false },
      },
    },
  },
}
