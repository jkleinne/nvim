-- Set leader key to space
vim.g.mapleader = " "

-- Set general Neovim options
vim.opt.number = true
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2

-- Ensure the default shell is zsh if it's installed
local zsh_path = vim.fn.exepath("zsh")
if zsh_path ~= "" then
  vim.opt.shell = zsh_path
else
  vim.opt.shell = "/bin/bash"
end

-- Automatically set the local working directory to the current file's directory
vim.cmd([[
  autocmd BufEnter * silent! lcd %:p:h
]])

-- Automatically reveal the current file in Neo-tree and force a change to its directory
vim.cmd([[
  autocmd VimEnter * Neotree source=filesystem reveal=true reveal_force_cwd=true
]])

-- Automatically close Neovim if Neo-tree is the last open window
vim.cmd([[
  autocmd BufEnter * ++nested if winnr('$') == 1 && &filetype == 'neo-tree' | quit | endif
]])

-- Disable line numbers on terminal buffers
vim.cmd([[
  autocmd TermOpen * setlocal nonumber norelativenumber
]])

vim.cmd([[
  autocmd FileType neo-tree setlocal nonumber norelativenumber
]])
