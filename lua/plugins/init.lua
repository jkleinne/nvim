-- Function to load all Lua files in the 'plugins' directory
local plugins = {}

-- Get a list of all Lua files in the plugins directory
local plugin_files = vim.fn.globpath(vim.fn.stdpath('config') .. '/lua/plugins', '*.lua', false, true)

for _, file in ipairs(plugin_files) do
  -- Extract the filename without extension
  local plugin_name = vim.fn.fnamemodify(file, ':t:r')
  if plugin_name ~= 'init' then  -- Skip init.lua to prevent recursion
      table.insert(plugins, require('plugins.' .. plugin_name))
  end
end

-- Setup lazy.nvim with the collected plugins
require('lazy').setup(plugins, {
  defaults = {
    lazy = true
  },
  install = {
    missing = true
  },
  change_detection = {
    enabled = true,
    notify = true
  }
})
