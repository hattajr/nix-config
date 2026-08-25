-- Disable inline diagnostic messages (virtual text) to reduce noise.
-- Warnings still show via gutter signs and the statusline count.
return {
  "neovim/nvim-lspconfig",
  opts = {
    diagnostics = {
      virtual_text = false,
    },
  },
}
