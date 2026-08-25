-- blink: a Neovim port of the Rainglow "blink" VSCode theme.
-- Faithful to blink's defined TextMate scopes; token types VSCode never defined
-- are filled in from blink's own terminal/ansi palette to keep everything in-hue.
-- Source: https://github.com/rainglow/vscode/blob/master/themes/blink.json

vim.cmd.highlight("clear")
if vim.g.syntax_on then
  vim.cmd.syntax("reset")
end

vim.o.background = "dark"
vim.o.termguicolors = true
vim.g.colors_name = "blink"

-- Palette lifted directly from blink.json ------------------------------------
local c = {
  -- backgrounds
  bg = "#283035", -- editor.background
  bg_highlight = "#2f383e", -- editor.lineHighlightBackground / editorGroup
  bg_sidebar = "#333d44", -- sideBar.background
  bg_header = "#3a454c", -- sideBarSectionHeader.background
  bg_dark = "#242b2f", -- editorGutter / dropdown
  bg_darker = "#1d2326", -- input / terminal
  bg_darkest = "#1f2529", -- titleBar / peekView
  bg_widget = "#3e4a52", -- panel / editorWidget / indent guide
  bg_visual = "#315c5e", -- editor.selectionBackground (#43b5b355 flattened)

  -- foregrounds
  fg = "#c0ccdb", -- editor.foreground
  fg_muted = "#8698a3", -- tab.inactiveForeground
  fg_gutter = "#54656f", -- editorLineNumber / border
  comment = "#4e5c66", -- comment (faithful: intentionally dim)
  indent = "#3e4a52", -- editorIndentGuide
  white = "#ffffff", -- variable.parameter (faithful: loud white)

  -- syntax accents (from blink tokenColors)
  teal = "#43b5b3", -- entity.name.function / support.function
  blue = "#5298c4", -- storage.type / entity.name.tag / keyword.other.use
  orange = "#d4856a", -- keyword / storage / class / attribute / constant
  string = "#84c4ce", -- string
  number = "#529ca8", -- constant.numeric
  keyword_dim = "#6f8391", -- keyword.other

  -- diagnostics / git / diff (from blink UI colors)
  red = "#e61f44", -- deleted / error
  red_soft = "#cf433e", -- invalid
  green = "#a7da1e", -- added / untracked
  green_diff = "#a6e22e", -- markup.inserted
  yellow = "#f7b83d", -- modified / changed / warning
  purple = "#9d37fc", -- conflict / info notification
  hint = "#6f8391", -- diagnostic hint (slate, distinct from Info blue)

  -- enrichment pulled from blink's terminal ansi palette
  soft_blue = "#9ec5de", -- ansiBrightGreen: members/fields
  soft_cyan = "#8ad4d2", -- ansiBrightCyan: escapes/regex
  soft_peach = "#ebc6b9", -- ansiBrightMagenta: builtin variables
  ansi_white = "#d0d9e4", -- ansiWhite
  red_bright = "#f03e5f", -- ansiBrightRed
  red_dark = "#ba0e2e", -- ansiRed

  none = "NONE",
}

local function hl(group, opts)
  vim.api.nvim_set_hl(0, group, opts)
end

-- Editor UI -------------------------------------------------------------------
local ui = {
  Normal = { fg = c.fg, bg = c.bg },
  NormalNC = { fg = c.fg, bg = c.bg },
  NormalFloat = { fg = c.fg, bg = c.bg_dark },
  FloatBorder = { fg = c.fg_gutter, bg = c.bg_dark },
  FloatTitle = { fg = c.blue, bg = c.bg_dark, bold = true },
  ColorColumn = { bg = c.bg_highlight },
  Cursor = { fg = c.bg, bg = c.white },
  lCursor = { fg = c.bg, bg = c.white },
  CursorIM = { fg = c.bg, bg = c.white },
  CursorLine = { bg = c.bg_highlight },
  CursorColumn = { bg = c.bg_highlight },
  CursorLineNr = { fg = c.blue, bold = true },
  LineNr = { fg = c.fg_gutter },
  LineNrAbove = { fg = c.fg_gutter },
  LineNrBelow = { fg = c.fg_gutter },
  SignColumn = { fg = c.fg_gutter, bg = c.bg },
  FoldColumn = { fg = c.fg_gutter, bg = c.bg },
  Folded = { fg = c.fg_muted, bg = c.bg_highlight },
  VertSplit = { fg = c.bg_darkest },
  WinSeparator = { fg = c.bg_darkest },
  Visual = { bg = c.bg_visual },
  VisualNOS = { bg = c.bg_visual },
  Search = { fg = "#333333", bg = "#ffe792" }, -- findHighlight
  IncSearch = { fg = c.bg, bg = c.orange },
  CurSearch = { fg = c.bg, bg = c.orange },
  Substitute = { fg = c.bg, bg = c.red },
  MatchParen = { fg = c.orange, bold = true },
  NonText = { fg = c.indent },
  Whitespace = { fg = c.indent },
  SpecialKey = { fg = c.indent },
  Conceal = { fg = c.fg_muted },
  EndOfBuffer = { fg = c.bg },
  Directory = { fg = c.blue },
  Title = { fg = c.orange, bold = true },
  ErrorMsg = { fg = c.red_bright },
  WarningMsg = { fg = c.yellow },
  MoreMsg = { fg = c.teal },
  ModeMsg = { fg = c.fg, bold = true },
  Question = { fg = c.teal },
  QuickFixLine = { bg = c.bg_highlight, bold = true },
  Winbar = { fg = c.fg_muted, bg = c.none },
  WinbarNC = { fg = c.fg_muted, bg = c.none },

  -- popup menu (dropdown palette)
  Pmenu = { fg = c.fg, bg = c.bg_dark },
  PmenuSel = { fg = c.white, bg = c.fg_gutter },
  PmenuSbar = { bg = c.bg_dark },
  PmenuThumb = { bg = c.fg_gutter },
  WildMenu = { fg = c.white, bg = c.fg_gutter },

  -- statusline / tabs
  StatusLine = { fg = c.white, bg = c.bg_darkest },
  StatusLineNC = { fg = c.fg_muted, bg = c.bg_darkest },
  TabLine = { fg = c.fg_muted, bg = c.bg_darkest },
  TabLineFill = { bg = c.bg_darkest },
  TabLineSel = { fg = c.fg, bg = c.bg },
}

-- Legacy syntax groups --------------------------------------------------------
local syntax = {
  Comment = { fg = c.comment, italic = true },
  Constant = { fg = c.orange },
  String = { fg = c.string },
  Character = { fg = c.string },
  Number = { fg = c.number },
  Float = { fg = c.number },
  Boolean = { fg = c.orange },
  Identifier = { fg = c.fg },
  Function = { fg = c.teal },
  Statement = { fg = c.orange },
  Conditional = { fg = c.orange },
  Repeat = { fg = c.orange },
  Label = { fg = c.orange },
  Operator = { fg = c.keyword_dim },
  Keyword = { fg = c.orange },
  Exception = { fg = c.orange },
  PreProc = { fg = c.blue },
  Include = { fg = c.blue },
  Define = { fg = c.blue },
  Macro = { fg = c.blue },
  PreCondit = { fg = c.blue },
  Type = { fg = c.blue },
  StorageClass = { fg = c.orange },
  Structure = { fg = c.blue },
  Typedef = { fg = c.blue },
  Special = { fg = c.teal },
  SpecialChar = { fg = c.soft_cyan },
  Tag = { fg = c.blue },
  Delimiter = { fg = c.keyword_dim },
  SpecialComment = { fg = c.fg_muted, italic = true },
  Debug = { fg = c.red },
  Underlined = { fg = c.blue, underline = true },
  Ignore = { fg = c.fg_gutter },
  Error = { fg = c.red_soft, bg = "#664e4d" }, -- invalid (faithful)
  Todo = { fg = c.bg, bg = c.yellow, bold = true },
  Added = { fg = c.green },
  Changed = { fg = c.yellow },
  Removed = { fg = c.red_bright },
}

-- Treesitter captures (enriched, but faithful where blink was explicit) -------
local treesitter = {
  ["@comment"] = { link = "Comment" },
  ["@comment.error"] = { fg = c.red },
  ["@comment.warning"] = { fg = c.yellow },
  ["@comment.todo"] = { fg = c.bg, bg = c.yellow, bold = true },
  ["@comment.note"] = { fg = c.bg, bg = c.teal, bold = true },

  ["@constant"] = { fg = c.orange }, -- constant.language -> orange
  ["@constant.builtin"] = { fg = c.orange },
  ["@constant.macro"] = { fg = c.blue },
  ["@string"] = { fg = c.string },
  ["@string.regexp"] = { fg = c.soft_cyan },
  ["@string.escape"] = { fg = c.soft_cyan },
  ["@string.special"] = { fg = c.soft_cyan },
  ["@character"] = { fg = c.string },
  ["@character.special"] = { fg = c.soft_cyan },
  ["@number"] = { fg = c.number },
  ["@number.float"] = { fg = c.number },
  ["@boolean"] = { fg = c.orange },

  ["@variable"] = { fg = c.fg },
  ["@variable.builtin"] = { fg = c.soft_peach }, -- self/this etc (enrichment)
  ["@variable.parameter"] = { fg = c.white }, -- faithful: white params
  ["@variable.member"] = { fg = c.soft_blue }, -- fields/properties (enrichment)

  ["@property"] = { fg = c.soft_blue },
  ["@field"] = { fg = c.soft_blue },

  ["@function"] = { fg = c.teal },
  ["@function.builtin"] = { fg = c.teal },
  ["@function.call"] = { fg = c.teal },
  ["@function.macro"] = { fg = c.teal },
  ["@function.method"] = { fg = c.teal },
  ["@function.method.call"] = { fg = c.teal },
  ["@constructor"] = { fg = c.orange }, -- class -> orange

  ["@keyword"] = { fg = c.orange },
  ["@keyword.function"] = { fg = c.orange },
  ["@keyword.operator"] = { fg = c.orange },
  ["@keyword.return"] = { fg = c.orange },
  ["@keyword.conditional"] = { fg = c.orange },
  ["@keyword.repeat"] = { fg = c.orange },
  ["@keyword.exception"] = { fg = c.orange },
  ["@keyword.import"] = { fg = c.blue }, -- keyword.other.use -> blue
  ["@keyword.include"] = { fg = c.blue },
  ["@keyword.directive"] = { fg = c.blue },

  ["@type"] = { fg = c.blue }, -- storage.type -> blue
  ["@type.builtin"] = { fg = c.blue },
  ["@type.definition"] = { fg = c.blue },
  ["@type.qualifier"] = { fg = c.orange },
  ["@storageclass"] = { fg = c.orange },
  ["@attribute"] = { fg = c.orange }, -- attribute-name -> orange
  ["@namespace"] = { fg = c.blue }, -- keyword.other.namespace -> blue
  ["@module"] = { fg = c.blue },

  ["@operator"] = { fg = c.keyword_dim },
  ["@punctuation.delimiter"] = { fg = c.keyword_dim },
  ["@punctuation.bracket"] = { fg = c.fg }, -- bracketsForeground -> fg
  ["@punctuation.special"] = { fg = c.orange },

  ["@label"] = { fg = c.orange },
  ["@decorator"] = { fg = c.orange },

  -- Markup (markdown) -- faithful to blink's markdown scopes
  ["@markup.heading"] = { fg = c.orange, bold = true },
  ["@markup.heading.1.markdown"] = { fg = c.orange, bold = true },
  ["@markup.heading.2.markdown"] = { fg = c.orange, bold = true },
  ["@markup.strong"] = { fg = c.blue, bold = true },
  ["@markup.italic"] = { fg = c.blue, italic = true },
  ["@markup.strikethrough"] = { fg = c.fg_muted, strikethrough = true },
  ["@markup.raw"] = { fg = c.string }, -- inline code
  ["@markup.raw.block"] = { fg = c.comment },
  ["@markup.link"] = { fg = c.blue },
  ["@markup.link.url"] = { fg = c.blue, underline = true },
  ["@markup.link.label"] = { fg = c.orange },
  ["@markup.list"] = { fg = c.orange },
  ["@markup.quote"] = { fg = c.comment, italic = true },

  -- Tags (html/jsx)
  ["@tag"] = { fg = c.blue }, -- entity.name.tag -> blue
  ["@tag.builtin"] = { fg = c.blue },
  ["@tag.attribute"] = { fg = c.orange }, -- attribute -> orange
  ["@tag.delimiter"] = { fg = c.keyword_dim },

  -- Diffs
  ["@diff.plus"] = { fg = c.green_diff },
  ["@diff.minus"] = { fg = c.red_bright },
  ["@diff.delta"] = { fg = c.yellow },
}

-- LSP semantic tokens ---------------------------------------------------------
local lsp = {
  ["@lsp.type.class"] = { fg = c.orange },
  ["@lsp.type.decorator"] = { fg = c.orange },
  ["@lsp.type.enum"] = { fg = c.blue },
  ["@lsp.type.enumMember"] = { fg = c.orange },
  ["@lsp.type.function"] = { fg = c.teal },
  ["@lsp.type.interface"] = { fg = c.blue },
  ["@lsp.type.macro"] = { fg = c.blue },
  ["@lsp.type.method"] = { fg = c.teal },
  ["@lsp.type.namespace"] = { fg = c.blue },
  ["@lsp.type.parameter"] = { fg = c.white },
  ["@lsp.type.property"] = { fg = c.soft_blue },
  ["@lsp.type.struct"] = { fg = c.blue },
  ["@lsp.type.type"] = { fg = c.blue },
  ["@lsp.type.typeParameter"] = { fg = c.blue },
  ["@lsp.type.variable"] = { fg = c.fg },
  ["@lsp.type.keyword"] = { fg = c.orange },
  ["@lsp.type.string"] = { fg = c.string },
  ["@lsp.type.number"] = { fg = c.number },
  ["@lsp.type.comment"] = { fg = c.comment },
  ["@lsp.mod.readonly"] = { fg = c.orange },
  ["@lsp.mod.deprecated"] = { fg = c.red_soft, strikethrough = true },
  ["@lsp.typemod.variable.readonly"] = { fg = c.orange },

  LspReferenceText = { bg = c.bg_widget },
  LspReferenceRead = { bg = c.bg_widget },
  LspReferenceWrite = { bg = c.bg_widget },
  LspInlayHint = { fg = c.fg_gutter, bg = c.bg_highlight, italic = true },
  LspCodeLens = { fg = c.comment, italic = true },
  LspSignatureActiveParameter = { fg = c.orange, bold = true },
}

-- Diagnostics -----------------------------------------------------------------
local diagnostics = {
  -- Signs (gutter) carry the full, loud severity color for quick spotting.
  DiagnosticError = { fg = c.red },
  DiagnosticWarn = { fg = c.yellow },
  DiagnosticInfo = { fg = c.blue },
  DiagnosticHint = { fg = c.hint },
  DiagnosticOk = { fg = c.green },
  DiagnosticUnderlineError = { undercurl = true, sp = c.red },
  DiagnosticUnderlineWarn = { undercurl = true, sp = c.yellow },
  DiagnosticUnderlineInfo = { undercurl = true, sp = c.blue },
  DiagnosticUnderlineHint = { undercurl = true, sp = c.hint },
  DiagnosticUnnecessary = { fg = c.comment },
  DiagnosticDeprecated = { fg = c.fg_muted, strikethrough = true },
}

-- Diff / git ------------------------------------------------------------------
local diff = {
  DiffAdd = { bg = "#2c3a2c" },
  DiffChange = { bg = "#333d2a" },
  DiffDelete = { bg = "#3a2a2f" },
  DiffText = { bg = "#4a4a2a" },
  diffAdded = { fg = c.green },
  diffRemoved = { fg = c.red_bright },
  diffChanged = { fg = c.yellow },
  diffFile = { fg = c.blue },
  diffLine = { fg = c.comment },

  GitSignsAdd = { fg = c.green },
  GitSignsChange = { fg = c.yellow },
  GitSignsDelete = { fg = c.red },
  GitSignsAddNr = { fg = c.green },
  GitSignsChangeNr = { fg = c.yellow },
  GitSignsDeleteNr = { fg = c.red },
  GitSignsCurrentLineBlame = { fg = c.fg_gutter, italic = true },
}

-- Plugins commonly used by LazyVim -------------------------------------------
local plugins = {
  -- neo-tree
  NeoTreeNormal = { fg = c.fg, bg = c.bg_sidebar },
  NeoTreeNormalNC = { fg = c.fg, bg = c.bg_sidebar },
  NeoTreeWinSeparator = { fg = c.bg_darkest, bg = c.bg_sidebar },
  NeoTreeEndOfBuffer = { fg = c.bg_sidebar, bg = c.bg_sidebar },
  NeoTreeRootName = { fg = c.orange, bold = true },
  NeoTreeDirectoryName = { fg = c.fg },
  NeoTreeDirectoryIcon = { fg = c.blue },
  NeoTreeFileName = { fg = c.fg },
  NeoTreeGitModified = { fg = c.yellow },
  NeoTreeGitAdded = { fg = c.green },
  NeoTreeGitDeleted = { fg = c.red },
  NeoTreeGitUntracked = { fg = c.green },
  NeoTreeGitIgnored = { fg = c.fg_gutter },
  NeoTreeGitConflict = { fg = c.purple },
  NeoTreeIndentMarker = { fg = c.indent },
  NeoTreeSymbolicLinkTarget = { fg = c.teal },

  -- telescope
  TelescopeNormal = { fg = c.fg, bg = c.bg_dark },
  TelescopeBorder = { fg = c.fg_gutter, bg = c.bg_dark },
  TelescopePromptNormal = { fg = c.fg, bg = c.bg_darker },
  TelescopePromptBorder = { fg = c.fg_gutter, bg = c.bg_darker },
  TelescopePromptTitle = { fg = c.bg, bg = c.orange, bold = true },
  TelescopePreviewTitle = { fg = c.bg, bg = c.teal, bold = true },
  TelescopeResultsTitle = { fg = c.bg, bg = c.blue, bold = true },
  TelescopeSelection = { fg = c.white, bg = c.fg_gutter },
  TelescopeMatching = { fg = c.orange, bold = true },
  TelescopePromptPrefix = { fg = c.orange },

  -- snacks (LazyVim default picker/dashboard/notifier)
  SnacksNormal = { fg = c.fg, bg = c.bg_dark },
  SnacksBackdrop = { bg = c.bg_darkest },
  SnacksPickerBorder = { fg = c.fg_gutter, bg = c.bg_dark },
  SnacksPickerMatch = { fg = c.orange, bold = true },
  SnacksPickerSelected = { fg = c.orange },
  SnacksPickerDir = { fg = c.fg_muted },
  SnacksPickerTitle = { fg = c.orange, bold = true },
  SnacksDashboardHeader = { fg = c.blue },
  SnacksDashboardTitle = { fg = c.orange },
  SnacksDashboardDesc = { fg = c.fg },
  SnacksDashboardKey = { fg = c.teal },
  SnacksDashboardIcon = { fg = c.orange },
  SnacksDashboardFooter = { fg = c.comment },
  SnacksIndent = { fg = c.indent },
  SnacksIndentScope = { fg = c.fg_gutter },

  -- indent-blankline
  IblIndent = { fg = c.indent },
  IblScope = { fg = c.fg_gutter },

  -- which-key
  WhichKey = { fg = c.orange },
  WhichKeyGroup = { fg = c.blue },
  WhichKeyDesc = { fg = c.fg },
  WhichKeySeparator = { fg = c.comment },
  WhichKeyFloat = { bg = c.bg_dark },
  WhichKeyBorder = { fg = c.fg_gutter, bg = c.bg_dark },

  -- nvim-cmp / blink.cmp
  CmpItemAbbr = { fg = c.fg },
  CmpItemAbbrDeprecated = { fg = c.fg_muted, strikethrough = true },
  CmpItemAbbrMatch = { fg = c.orange, bold = true },
  CmpItemAbbrMatchFuzzy = { fg = c.orange, bold = true },
  CmpItemKind = { fg = c.blue },
  CmpItemMenu = { fg = c.comment },
  BlinkCmpMenu = { fg = c.fg, bg = c.bg_dark },
  BlinkCmpMenuBorder = { fg = c.fg_gutter, bg = c.bg_dark },
  BlinkCmpLabelMatch = { fg = c.orange, bold = true },
  BlinkCmpKind = { fg = c.blue },

  -- notify / noice
  NotifyERRORBorder = { fg = c.red },
  NotifyWARNBorder = { fg = c.yellow },
  NotifyINFOBorder = { fg = c.blue },
  NotifyDEBUGBorder = { fg = c.comment },
  NotifyTRACEBorder = { fg = c.purple },
  NotifyERRORTitle = { fg = c.red },
  NotifyWARNTitle = { fg = c.yellow },
  NotifyINFOTitle = { fg = c.blue },
  NoiceCmdlinePopupBorder = { fg = c.fg_gutter },
  NoiceCmdlineIcon = { fg = c.orange },

  -- lazy / mason
  LazyProgressdone = { fg = c.orange, bold = true },
  LazyProgressTodo = { fg = c.fg_gutter },
  LazyH1 = { fg = c.bg, bg = c.orange, bold = true },
  MasonHeader = { fg = c.bg, bg = c.orange, bold = true },
  MasonHighlight = { fg = c.teal },
  MasonMuted = { fg = c.fg_muted },

  -- mini.nvim
  MiniStatuslineModeNormal = { fg = c.bg, bg = c.blue, bold = true },
  MiniStatuslineModeInsert = { fg = c.bg, bg = c.green, bold = true },
  MiniStatuslineModeVisual = { fg = c.bg, bg = c.orange, bold = true },
  MiniStatuslineModeReplace = { fg = c.bg, bg = c.red, bold = true },
  MiniStatuslineModeCommand = { fg = c.bg, bg = c.yellow, bold = true },
  MiniIconsAzure = { fg = c.blue },
  MiniIconsBlue = { fg = c.blue },
  MiniIconsCyan = { fg = c.teal },
  MiniIconsGreen = { fg = c.green },
  MiniIconsGrey = { fg = c.fg_muted },
  MiniIconsOrange = { fg = c.orange },
  MiniIconsPurple = { fg = c.purple },
  MiniIconsRed = { fg = c.red },
  MiniIconsYellow = { fg = c.yellow },

  -- flash / leap
  FlashLabel = { fg = c.bg, bg = c.orange, bold = true },
  FlashMatch = { fg = c.orange },

  -- treesitter-context (present in your config)
  TreesitterContext = { bg = c.bg_highlight },
  TreesitterContextLineNumber = { fg = c.fg_gutter, bg = c.bg_highlight },

  -- diffview (present in your config)
  DiffviewNormal = { fg = c.fg, bg = c.bg_dark },
  DiffviewFilePanelTitle = { fg = c.orange, bold = true },
  DiffviewFilePanelCounter = { fg = c.blue },
  DiffviewStatusAdded = { fg = c.green },
  DiffviewStatusModified = { fg = c.yellow },
  DiffviewStatusDeleted = { fg = c.red },
}

-- Plugins enabled in this LazyVim install that don't self-derive cleanly ------
local plugins_ext = {
  -- bufferline.nvim (default buffer/tab bar)
  BufferLineFill = { bg = c.bg_darkest },
  BufferLineBackground = { fg = c.fg_muted, bg = c.bg_darkest },
  BufferLineBufferVisible = { fg = c.fg_muted, bg = c.bg_dark },
  BufferLineBufferSelected = { fg = c.fg, bg = c.bg, bold = true, italic = true },
  BufferLineModified = { fg = c.yellow, bg = c.bg_darkest },
  BufferLineModifiedVisible = { fg = c.yellow, bg = c.bg_dark },
  BufferLineModifiedSelected = { fg = c.yellow, bg = c.bg },
  BufferLineIndicatorVisible = { fg = c.bg_dark, bg = c.bg_dark },
  BufferLineIndicatorSelected = { fg = c.orange, bg = c.bg },
  BufferLineSeparator = { fg = c.bg_darkest, bg = c.bg_darkest },
  BufferLineSeparatorVisible = { fg = c.bg_darkest, bg = c.bg_dark },
  BufferLineSeparatorSelected = { fg = c.bg_darkest, bg = c.bg },
  BufferLineCloseButton = { fg = c.fg_muted, bg = c.bg_darkest },
  BufferLineCloseButtonVisible = { fg = c.fg_muted, bg = c.bg_dark },
  BufferLineCloseButtonSelected = { fg = c.red, bg = c.bg },
  BufferLineTab = { fg = c.fg_muted, bg = c.bg_darkest },
  BufferLineTabSelected = { fg = c.orange, bg = c.bg },
  BufferLineTabClose = { fg = c.red, bg = c.bg_darkest },
  BufferLineDuplicate = { fg = c.fg_muted, bg = c.bg_darkest, italic = true },
  BufferLineDuplicateVisible = { fg = c.fg_muted, bg = c.bg_dark, italic = true },
  BufferLineDuplicateSelected = { fg = c.fg, bg = c.bg, italic = true },
  BufferLinePick = { fg = c.orange, bg = c.bg_darkest, bold = true },
  BufferLinePickVisible = { fg = c.orange, bg = c.bg_dark, bold = true },
  BufferLinePickSelected = { fg = c.orange, bg = c.bg, bold = true },
  BufferLineError = { fg = c.red, bg = c.bg_darkest },
  BufferLineErrorSelected = { fg = c.red, bg = c.bg },
  BufferLineWarning = { fg = c.yellow, bg = c.bg_darkest },
  BufferLineWarningSelected = { fg = c.yellow, bg = c.bg },
  BufferLineInfo = { fg = c.blue, bg = c.bg_darkest },
  BufferLineInfoSelected = { fg = c.blue, bg = c.bg },

  -- trouble.nvim
  TroubleNormal = { fg = c.fg, bg = c.bg_dark },
  TroubleNormalNC = { fg = c.fg, bg = c.bg_dark },
  TroubleText = { fg = c.fg },
  TroubleCount = { fg = c.orange, bold = true },
  TroubleFoldIcon = { fg = c.fg_muted },
  TroubleIndent = { fg = c.indent },
  TroublePos = { fg = c.fg_muted },
  TroubleSource = { fg = c.comment },

  -- todo-comments.nvim (keyword -> diagnostic role, matching blink palette)
  TodoFgFIX = { fg = c.red },
  TodoBgFIX = { fg = c.bg, bg = c.red, bold = true },
  TodoSignFIX = { fg = c.red },
  TodoFgTODO = { fg = c.blue },
  TodoBgTODO = { fg = c.bg, bg = c.blue, bold = true },
  TodoSignTODO = { fg = c.blue },
  TodoFgHACK = { fg = c.yellow },
  TodoBgHACK = { fg = c.bg, bg = c.yellow, bold = true },
  TodoSignHACK = { fg = c.yellow },
  TodoFgWARN = { fg = c.yellow },
  TodoBgWARN = { fg = c.bg, bg = c.yellow, bold = true },
  TodoSignWARN = { fg = c.yellow },
  TodoFgPERF = { fg = c.purple },
  TodoBgPERF = { fg = c.bg, bg = c.purple, bold = true },
  TodoSignPERF = { fg = c.purple },
  TodoFgNOTE = { fg = c.teal },
  TodoBgNOTE = { fg = c.bg, bg = c.teal, bold = true },
  TodoSignNOTE = { fg = c.teal },
  TodoFgTEST = { fg = c.purple },
  TodoBgTEST = { fg = c.bg, bg = c.purple, bold = true },
  TodoSignTEST = { fg = c.purple },

  -- render-markdown.nvim
  RenderMarkdownH1 = { fg = c.orange, bold = true },
  RenderMarkdownH2 = { fg = c.orange, bold = true },
  RenderMarkdownH3 = { fg = c.blue, bold = true },
  RenderMarkdownH4 = { fg = c.blue, bold = true },
  RenderMarkdownH5 = { fg = c.teal, bold = true },
  RenderMarkdownH6 = { fg = c.teal, bold = true },
  RenderMarkdownH1Bg = { fg = c.orange, bg = c.bg_highlight },
  RenderMarkdownH2Bg = { fg = c.orange, bg = c.bg_highlight },
  RenderMarkdownH3Bg = { fg = c.blue, bg = c.bg_highlight },
  RenderMarkdownH4Bg = { fg = c.blue, bg = c.bg_highlight },
  RenderMarkdownH5Bg = { fg = c.teal, bg = c.bg_highlight },
  RenderMarkdownH6Bg = { fg = c.teal, bg = c.bg_highlight },
  RenderMarkdownCode = { bg = c.bg_dark },
  RenderMarkdownCodeInline = { fg = c.string, bg = c.bg_dark },
  RenderMarkdownBullet = { fg = c.orange },
  RenderMarkdownDash = { fg = c.fg_gutter },
  RenderMarkdownQuote = { fg = c.comment },
  RenderMarkdownLink = { fg = c.blue, underline = true },
  RenderMarkdownTableHead = { fg = c.fg_muted },
  RenderMarkdownTableRow = { fg = c.fg_muted },
  RenderMarkdownChecked = { fg = c.green },
  RenderMarkdownUnchecked = { fg = c.fg_gutter },

  -- grug-far.nvim (search/replace)
  GrugFarResultsMatch = { fg = c.orange, bold = true },
  GrugFarResultsPath = { fg = c.blue },
  GrugFarResultsLineNo = { fg = c.fg_gutter },
  GrugFarResultsLineColumn = { fg = c.fg_gutter },
  GrugFarResultsChangeIndicator = { fg = c.green },
  GrugFarInputLabel = { fg = c.orange },
}

-- Apply all -------------------------------------------------------------------
for _, groups in ipairs({ ui, syntax, treesitter, lsp, diagnostics, diff, plugins, plugins_ext }) do
  for group, opts in pairs(groups) do
    hl(group, opts)
  end
end

-- Terminal colors (from blink's ansi palette) --------------------------------
vim.g.terminal_color_0 = "#333d44"
vim.g.terminal_color_1 = c.red_dark
vim.g.terminal_color_2 = "#5298c4"
vim.g.terminal_color_3 = c.orange
vim.g.terminal_color_4 = c.teal
vim.g.terminal_color_5 = c.orange
vim.g.terminal_color_6 = c.teal
vim.g.terminal_color_7 = c.ansi_white
vim.g.terminal_color_8 = c.fg_gutter
vim.g.terminal_color_9 = c.red_bright
vim.g.terminal_color_10 = c.soft_blue
vim.g.terminal_color_11 = c.soft_peach
vim.g.terminal_color_12 = c.soft_cyan
vim.g.terminal_color_13 = c.soft_peach
vim.g.terminal_color_14 = c.soft_cyan
vim.g.terminal_color_15 = c.white
