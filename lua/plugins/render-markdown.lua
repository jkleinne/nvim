return {
  'MeanderingProgrammer/render-markdown.nvim',
  enabled = false, -- disabled: incompatible with Neovim 0.12 treesitter API (re-enable after plugin or Neovim update)
  dependencies = { 'nvim-treesitter/nvim-treesitter', 'nvim-tree/nvim-web-devicons' },
  ---@module 'render-markdown'
  ---@type render.md.UserConfig
  opts = {},
}
