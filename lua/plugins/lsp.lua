-- ts_ls uses a system TypeScript: Arch's typescript package, else the tsserver on PATH
-- (typescript-language-server resolves its bin script to the package's lib/tsserver.js).
-- Empty when there is none.
local function system_tsserver_path()
  local arch_tsserver = "/usr/lib/node_modules/typescript/lib/tsserver.js"
  if vim.uv.fs_stat(arch_tsserver) then
    return arch_tsserver
  end
  return vim.fn.exepath "tsserver"
end

-- terraform-ls runs `terraform providers schema`, which executes provider binaries from a repo's
-- .terraform directory. When the terraform CLI is installed, start it only in directories trusted
-- through Neovim's trust database (:help vim.secure.read()). Answers other than "allow" are
-- remembered for the session so the prompt is not repeated; "allow" is re-checked so
-- `:trust ++remove <dir>` takes effect without a restart.
local untrusted_roots = {}

-- Whether vim.secure.read is about to ask about dir: it resolves and the trust database has no
-- line for it (format: runtime/lua/vim/secure.lua). This only decides whether to explain the
-- prompt; vim.secure.read stays the authority. If the format ever changes, the worst case is a
-- missing or extra notice.
local function trust_unanswered(dir)
  local path = vim.uv.fs_realpath(dir)
  if not path then
    return false
  end
  local f = io.open(vim.fn.stdpath "state" .. "/trust", "r")
  if not f then
    return true
  end
  local answered = false
  for line in f:lines() do
    local _, file = line:match "^(%S+) (.+)$"
    if file == path then
      answered = true
      break
    end
  end
  f:close()
  return not answered
end

local function root_trusted(root)
  if vim.fn.executable "terraform" == 0 then
    return true
  end
  if untrusted_roots[root] or #vim.api.nvim_list_uis() == 0 then
    return false
  end
  if trust_unanswered(root) then
    vim.notify(
      "terraform-ls runs provider plugins from "
        .. root
        .. "/.terraform; allow this directory in the next prompt to enable it",
      vim.log.levels.INFO
    )
  end
  if vim.secure.read(root) == true then
    return true
  end
  untrusted_roots[root] = true
  return false
end

-- lspconfig's terraformls root (nearest .terraform or .git, else the file's directory), handed
-- to Neovim only when trusted, so an untrusted root never starts the server
local function terraformls_root_dir(bufnr, on_dir)
  local root = vim.fs.root(bufnr, { ".terraform", ".git" }) or vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
  if root_trusted(root) then
    on_dir(root)
  end
end

return {
  "neovim/nvim-lspconfig",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = {
    "mason-org/mason.nvim",
    "mason-org/mason-lspconfig.nvim",
  },
  config = function()
    -- Each config run (for example :Lazy reload) starts a fresh session cache of declined roots
    untrusted_roots = {}

    -- Installed by Mason (native binaries, no npm)
    local mason_servers = {
      "gopls",
      "lua_ls",
      "sqls",
      "terraformls",
    }

    -- Installed by the system package manager (server = command it runs). These are Node programs;
    -- the Arch packages depend on nodejs, not npm. The commands are bare names found on PATH; setting
    -- them as lists means lspconfig's default lookup in root_dir/node_modules/.bin (jsonls, ts_ls,
    -- yamlls) is never used. A server is enabled only when its command is executable: a list cmd
    -- already skips a missing binary, but the gate keeps lsp.log free of errors and makes
    -- vim.lsp.is_enabled reflect what is installed.
    -- Keep in sync with install_language_servers in nvim-install.sh.
    local system_servers = {
      bashls = { "bash-language-server", "start" },
      dockerls = { "docker-langserver", "--stdio" },
      jsonls = { "vscode-json-language-server", "--stdio" },
      pyright = { "pyright-langserver", "--stdio" },
      ts_ls = { "typescript-language-server", "--stdio" },
      yamlls = { "yaml-language-server", "--stdio" },
    }

    local system_tsserver = system_tsserver_path()
    if system_tsserver == "" then
      -- Without a system TypeScript, ts_ls would load a repo's node_modules/typescript
      system_servers.ts_ls = nil
    end

    local capabilities = require("blink.cmp").get_lsp_capabilities()

    vim.lsp.config("*", {
      capabilities = capabilities,
    })

    vim.lsp.config("lua_ls", {
      settings = {
        Lua = {
          diagnostics = {
            globals = { "vim" },
          },
          telemetry = {
            enable = false,
          },
        },
      },
    })

    if system_servers.ts_ls then
      vim.lsp.config("ts_ls", { init_options = { tsserver = { path = system_tsserver } } })
    end

    vim.lsp.config("terraformls", { root_dir = terraformls_root_dir })

    local mason_lspconfig = require "mason-lspconfig"

    mason_lspconfig.setup {
      ensure_installed = mason_servers,
      automatic_enable = true,
    }

    local available = {}
    for server, cmd in pairs(system_servers) do
      if vim.fn.executable(cmd[1]) == 1 then
        vim.lsp.config(server, { cmd = cmd })
        table.insert(available, server)
      end
    end
    vim.lsp.enable(available)

    -- Set keymaps when an LSP attaches to a buffer
    vim.api.nvim_create_autocmd("LspAttach", {
      callback = function(args)
        local bufnr = args.buf
        local opts = { noremap = true, silent = true, buffer = bufnr }
        local keymap = vim.keymap.set

        keymap("n", "gl", vim.diagnostic.open_float, opts)
        keymap("n", "[d", function()
          vim.diagnostic.jump { count = -1, float = true }
        end, opts)
        keymap("n", "]d", function()
          vim.diagnostic.jump { count = 1, float = true }
        end, opts)
        keymap("n", "<leader>q", vim.diagnostic.setloclist, opts)

        keymap("n", "gd", vim.lsp.buf.definition, opts)
        keymap("n", "K", vim.lsp.buf.hover, opts)
        keymap("n", "gi", vim.lsp.buf.implementation, opts)
        keymap("n", "<C-k>", vim.lsp.buf.signature_help, opts)
        keymap("n", "<leader>wa", vim.lsp.buf.add_workspace_folder, opts)
        keymap("n", "<leader>wr", vim.lsp.buf.remove_workspace_folder, opts)
        keymap("n", "<leader>wl", function()
          print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
        end, opts)
        keymap("n", "<leader>D", vim.lsp.buf.type_definition, opts)
        keymap("n", "<leader>rn", vim.lsp.buf.rename, opts)
        keymap("n", "<leader>ca", vim.lsp.buf.code_action, opts)
        keymap("n", "gr", vim.lsp.buf.references, opts)
      end,
    })
  end,
}
