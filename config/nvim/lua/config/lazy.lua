local skip_plugin_install = vim.env.NIX_CONFIG_TEST_NO_PLUGIN_INSTALL == "1"
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- Home Manager deploys the configuration tree from the read-only Nix store.
-- Seed Lazy's lockfile into writable XDG state so first-run plugin installs and
-- later lock updates never try to modify ~/.config/nvim/lazy-lock.json.
local managed_lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json"
local lockfile = vim.fn.stdpath("state") .. "/lazy/lazy-lock.json"
vim.fn.mkdir(vim.fn.fnamemodify(lockfile, ":h"), "p")
if vim.fn.filereadable(lockfile) == 0 and vim.fn.filereadable(managed_lockfile) == 1 then
  local ok, lines = pcall(vim.fn.readfile, managed_lockfile)
  if ok then
    pcall(vim.fn.writefile, lines, lockfile)
  end
end

require("lazy").setup({
  lockfile = lockfile,
  spec = {
    -- add LazyVim and import its plugins
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    -- import/override with your plugins
    { import = "plugins" },
  },
  defaults = {
    -- By default, only LazyVim plugins will be lazy-loaded. Your custom plugins will load during startup.
    -- If you know what you're doing, you can set this to `true` to have all your custom plugins lazy-loaded by default.
    lazy = false,
    -- It's recommended to leave version=false for now, since a lot the plugin that support versioning,
    -- have outdated releases, which may break your Neovim install.
    version = false, -- always use the latest git commit
    -- version = "*", -- try installing the latest stable version for plugins that support semver
  },
  install = {
    colorscheme = { "blink", "habamax" },
    -- Validation only needs to exercise the real config and writable lockfile;
    -- avoid downloading the full plugin graph in disposable containers.
    missing = not skip_plugin_install,
  },
  checker = {
    enabled = not skip_plugin_install, -- check for plugin updates periodically
    notify = false, -- notify on update
  }, -- automatically check for plugin updates
  performance = {
    rtp = {
      -- disable some rtp plugins
      disabled_plugins = {
        "gzip",
        -- "matchit",
        -- "matchparen",
        -- "netrwPlugin",
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
      },
    },
  },
})
