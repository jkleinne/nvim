local map = vim.keymap.set
local default_opts =  { noremap = true, silent = true }

map('n', ';', ':', { desc = 'CMD enter command mode' })

map('i', 'jk', '<ESC>')

map('n', '<leader>x', ':bd!<CR>', default_opts)

-- Set kubectl.nvim toggle mapping
map('n', '<leader>k', '<cmd>lua require("kubectl").toggle()<cr>', default_opts)
-- Map <leader>gtt to open a terminal and run lazygit
map('n', '<leader>gtt', ':term lazygit<CR>i', default_opts)

-- Map <leader>tc to open a terminal and run lazydocker
map('n', '<leader>dc', ':term lazydocker<CR>i', default_opts)

-- Map <leader>tb to open an empty tab
map('n', '<leader>tb', ':enew<CR>', default_opts)

-- Map <leader>sq to open a terminal and run lazysql
map('n', '<leader>sq', ':term lazysql<CR>i', default_opts)

-- Map <leader>po to run 'posting --collection <posting-collection-path>'
map('n', '<leader>po', function()
  vim.ui.input({ prompt = 'Enter posting collection path: ' }, function(input)
    if input ~= nil and input ~= '' then
      vim.cmd('term posting --collection ' .. input)
    else
      vim.cmd('term posting')
    end
  end)
end, default_opts)

-- Keybindings for Telescope fuzzy finder
map('n', '<leader>ff', '<cmd>Telescope find_files<cr>', { noremap = true, silent = true })
map('n', '<leader>fg', '<cmd>Telescope live_grep<cr>', { noremap = true, silent = true })
map('n', '<leader>fb', '<cmd>Telescope buffers<cr>', { noremap = true, silent = true })
map('n', '<leader>fh', '<cmd>Telescope help_tags<cr>', { noremap = true, silent = true })

-- Neotree keybindings
map('n', '<C-e>', ':Neotree toggle<CR>', default_opts)
