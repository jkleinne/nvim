local map = vim.keymap.set
local default_opts = { noremap = true, silent = true }
local initial_cwd = vim.fn.getcwd()

local function keymap_opts(desc)
  return vim.tbl_extend("force", default_opts, { desc = desc })
end

map("n", "<leader>bd", ":Bdelete<CR>", keymap_opts "Delete buffer")

map("n", "<leader>k", '<cmd>lua require("kubectl").toggle()<cr>', keymap_opts "Toggle kubectl")

map("n", "<leader>gtt", ":term lazygit<CR>i", keymap_opts "Lazygit")
map("n", "<leader>dc", ":term lazydocker<CR>i", keymap_opts "Lazydocker")
map("n", "<leader>bn", ":enew<CR>", keymap_opts "New empty buffer")
map("n", "<leader>sq", ":term lazysql<CR>i", keymap_opts "Lazysql")

map("n", "<leader>po", function()
  vim.ui.input({ prompt = "Enter posting collection path: " }, function(input)
    local trimmed = input and vim.trim(input) or ""
    if trimmed ~= "" then
      local safe_input = vim.fn.shellescape(trimmed)
      vim.cmd("term posting --collection " .. safe_input)
    else
      vim.cmd "term posting"
    end
  end)
end, keymap_opts "Posting HTTP client")

map("n", "<leader>tf", "<cmd>Telescope find_files cwd=" .. initial_cwd .. "<cr>", keymap_opts "Find files")
map("n", "<leader>tg", "<cmd>Telescope live_grep cwd=" .. initial_cwd .. "<cr>", keymap_opts "Live grep")
map("n", "<leader>tb", "<cmd>Telescope buffers<cr>", keymap_opts "Buffers")
map("n", "<leader>th", "<cmd>Telescope help_tags<cr>", keymap_opts "Help tags")
map("n", "<leader>ts", "<cmd>Telescope luasnip<cr>", keymap_opts "Snippets")

map("n", "<TAB>", ":BufferLineCycleNext<CR>", keymap_opts "Next buffer")
map("n", "<S-TAB>", ":BufferLineCyclePrev<CR>", keymap_opts "Previous buffer")

map("n", "<C-w>t", ":tabnew<CR>", keymap_opts "New tab")

map("n", "<leader>h", ":belowright 20split | terminal<CR>", keymap_opts "Horizontal terminal split")
map("n", "<leader>v", ":vsplit | wincmd l | terminal<CR>", keymap_opts "Vertical terminal split")

-- Double-Esc to exit terminal mode; single Esc stays bound to TUI apps (lazygit, fzf, posting)
map("t", "<Esc><Esc>", "<C-\\><C-n>", keymap_opts "Exit terminal mode")
map("t", "<C-h>", "<C-\\><C-n><C-w>h", keymap_opts "Move to left window")
map("t", "<C-j>", "<C-\\><C-n><C-w>j", keymap_opts "Move to lower window")
map("t", "<C-k>", "<C-\\><C-n><C-w>k", keymap_opts "Move to upper window")
map("t", "<C-l>", "<C-\\><C-n><C-w>l", keymap_opts "Move to right window")
