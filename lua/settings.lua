-- Set leader key to space
vim.g.mapleader = " "

-- General options
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.signcolumn = "yes"
vim.opt.cursorline = true
vim.opt.scrolloff = 8
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.clipboard = "unnamedplus"
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.updatetime = 250
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2

-- Disable :intro page
vim.opt.shortmess:append "I"

-- Ensure the default shell is zsh if it's installed
local zsh_path = vim.fn.exepath "zsh"
if zsh_path ~= "" then
  vim.opt.shell = zsh_path
else
  vim.opt.shell = "/bin/bash"
end

-- Enable built-in treesitter highlighting
vim.api.nvim_create_autocmd("FileType", {
  callback = function()
    pcall(vim.treesitter.start)
  end,
})

-- Automatically close Neovim if Neo-tree is the last open window
vim.api.nvim_create_autocmd("BufEnter", {
  nested = true,
  callback = function()
    if vim.fn.winnr "$" == 1 and vim.bo.filetype == "neo-tree" then
      vim.cmd.quit()
    end
  end,
})

-- Disable line numbers on terminal buffers
vim.api.nvim_create_autocmd("TermOpen", {
  callback = function()
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
  end,
})

-- Disable line numbers for neo-tree
vim.api.nvim_create_autocmd("FileType", {
  pattern = "neo-tree",
  callback = function()
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
  end,
})
