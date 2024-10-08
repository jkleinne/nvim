require "nvchad.options"

-- Automatically close Neovim if NvimTree is the last open window
vim.cmd([[
  autocmd BufEnter * ++nested if winnr('$') == 1 && &filetype == 'NvimTree' | quit | endif
]])

-- Automatically open NvimTree when Neovim is started
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function(data)
    -- Check if the buffer is a directory or empty to prevent opening for a specific file
    local directory = vim.fn.isdirectory(data.file) == 1
    if directory or data.file == "" then
      require("nvim-tree.api").tree.open()
    end
  end,
})

-- Set general Neovim options
vim.opt.number = true        -- Enable line numbers
vim.opt.expandtab = true     -- Use spaces instead of tabs
vim.opt.smartindent = true   -- Enable smart indentation

-- Ensure the default shell is zsh if it's installed
local zsh_path = vim.fn.exepath("zsh")
if zsh_path ~= "" then
  vim.opt.shell = zsh_path
else
  vim.opt.shell = "/bin/bash"
end
