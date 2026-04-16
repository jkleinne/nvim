local map = vim.keymap.set
local default_opts = { noremap = true, silent = true }
local initial_cwd = vim.fn.getcwd()

local function opts(desc)
  return vim.tbl_extend("force", default_opts, { desc = desc })
end

map("n", "<leader>bd", ":Bdelete<CR>", opts "Delete buffer")

map("n", "<leader>k", '<cmd>lua require("kubectl").toggle()<cr>', opts "Toggle kubectl")

map("n", "<leader>gtt", ":term lazygit<CR>i", opts "Lazygit")
map("n", "<leader>dc", ":term lazydocker<CR>i", opts "Lazydocker")
map("n", "<leader>ta", ":enew<CR>", opts "New empty buffer")
map("n", "<leader>sq", ":term lazysql<CR>i", opts "Lazysql")

map("n", "<leader>po", function()
  vim.ui.input({ prompt = "Enter posting collection path: " }, function(input)
    if input and input ~= "" then
      local safe_input = vim.fn.shellescape(input)
      vim.cmd("term posting --collection " .. safe_input)
    else
      vim.cmd "term posting"
    end
  end)
end, opts "Posting HTTP client")

map("n", "<leader>tf", "<cmd>Telescope find_files cwd=" .. initial_cwd .. "<cr>", opts "Find files")
map("n", "<leader>tg", "<cmd>Telescope live_grep cwd=" .. initial_cwd .. "<cr>", opts "Live grep")
map("n", "<leader>tb", "<cmd>Telescope buffers<cr>", opts "Buffers")
map("n", "<leader>th", "<cmd>Telescope help_tags<cr>", opts "Help tags")
map("n", "<leader>ts", "<cmd>Telescope luasnip<cr>", opts "Snippets")

map("n", "<TAB>", ":BufferLineCycleNext<CR>", opts "Next buffer")
map("n", "<S-TAB>", ":BufferLineCyclePrev<CR>", opts "Previous buffer")

map("n", "<C-w>t", ":tabnew<CR>", opts "New tab")

map("n", "<leader>h", ":belowright 20split | terminal<CR>", opts "Horizontal terminal split")
map("n", "<leader>v", ":vsplit | wincmd l | terminal<CR>", opts "Vertical terminal split")

-- Double-Esc to exit terminal mode; single Esc stays bound to TUI apps (lazygit, fzf, posting)
map("t", "<Esc><Esc>", "<C-\\><C-n>", opts "Exit terminal mode")
map("t", "<C-h>", "<C-\\><C-n><C-w>h", opts "Move to left window")
map("t", "<C-j>", "<C-\\><C-n><C-w>j", opts "Move to lower window")
map("t", "<C-k>", "<C-\\><C-n><C-w>k", opts "Move to upper window")
map("t", "<C-l>", "<C-\\><C-n><C-w>l", opts "Move to right window")
