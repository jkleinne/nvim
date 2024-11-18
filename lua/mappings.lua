local map = vim.keymap.set
local default_opts = { noremap = true, silent = true }
local initial_cwd = vim.fn.getcwd()

map('n', '<leader>x', ':Bdelete <CR>', default_opts)

-- Set kubectl.nvim toggle mapping
map('n', '<leader>k', '<cmd>lua require("kubectl").toggle()<cr>', default_opts)
-- Map <leader>gtt to open a terminal and run lazygit
map('n', '<leader>gtt', ':term lazygit<CR>i', default_opts)

-- Map <leader>tc to open a terminal and run lazydocker
map('n', '<leader>dc', ':term lazydocker<CR>i', default_opts)

-- Map <leader>tb to open an empty tab
map('n', '<leader>ta', ':enew<CR>', default_opts)

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
map('n', '<leader>tf', '<cmd>Telescope find_files cwd=' .. initial_cwd .. '<cr>', default_opts)
map('n', '<leader>tg', '<cmd>Telescope live_grep  cwd=' .. initial_cwd .. '<cr>', default_opts)
map('n', '<leader>tb', '<cmd>Telescope buffers<cr>', default_opts)
map('n', '<leader>th', '<cmd>Telescope help_tags<cr>', default_opts)
map('n', '<leader>ts', '<cmd>Telescope luasnip<cr>', default_opts)

-- Neotree keybindings
map('n', '<C-e>', ':Neotree toggle reveal=true reveal_force_cwd=true<CR>', default_opts)

-- Bufferline & buffer mappings
map('n', '<TAB>', ':BufferLineCycleNext<CR>', default_opts)
map('n', '<S-TAB>', ':BufferLineCyclePrev<CR>', default_opts)

-- Scope mappings / tab management
map('n', '<C-w>t', ':tabnew<CR>', default_opts)

-- Terminal splits mappings
map('n', '<leader>h', ':belowright 20split | terminal<CR>', default_opts)
map('n', '<leader>v', ':vsplit | wincmd l | terminal<CR>', default_opts)
