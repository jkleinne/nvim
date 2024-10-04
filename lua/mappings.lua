require "nvchad.mappings"

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

-- Set kubectl.nvim toggle mapping
vim.keymap.set("n", "<leader>k", '<cmd>lua require("kubectl").toggle()<cr>', { noremap = true, silent = true })
-- Map <leader>gtt to open a terminal and run lazygit
map("n", "<leader>gtt", ":term lazygit<CR>i", { noremap = true, silent = true })

-- Map <leader>tc to open a terminal and run lazydocker
map('n', '<leader>dc', ':term lazydocker<CR>i', { noremap = true, silent = true })

-- Map <leader>tb to open an empty tab
map('n', '<leader>tb', ':enew<CR>', { noremap = true, silent = true })

-- Map <leader>sq to open a terminal and run lazysql
map('n', '<leader>sq', ':term lazysql<CR>i', { noremap = true, silent = true })
