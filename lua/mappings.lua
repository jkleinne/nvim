require "nvchad.mappings"

local map = vim.keymap.set
local default_opts =  { noremap = true, silent = true }

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

-- Set kubectl.nvim toggle mapping
vim.keymap.set("n", "<leader>k", '<cmd>lua require("kubectl").toggle()<cr>', default_opts)
-- Map <leader>gtt to open a terminal and run lazygit
map("n", "<leader>gtt", ":term lazygit<CR>i", default_opts)

-- Map <leader>tc to open a terminal and run lazydocker
map('n', '<leader>dc', ':term lazydocker<CR>i', default_opts)

-- Map <leader>tb to open an empty tab
map('n', '<leader>tb', ':enew<CR>', default_opts)

-- Map <leader>sq to open a terminal and run lazysql
map('n', '<leader>sq', ':term lazysql<CR>i', default_opts)
