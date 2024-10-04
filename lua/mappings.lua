require "nvchad.mappings"

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

-- Set kubectl.nvim toggle mapping
vim.keymap.set("n", "<leader>k", '<cmd>lua require("kubectl").toggle()<cr>', { noremap = true, silent = true })

local map = vim.api.nvim_set_keymap
local opts = { noremap = true, silent = true }

-- Map <leader>gtt to open a terminal and run lazygit
map("n", "<leader>gtt", ":term lazygit<CR>i", opts)

-- Map <leader>tb to open an empty tab
map('n', '<leader>tb', ':enew<CR>', { noremap = true, silent = true })
