-- Buffer-local LSP keymaps, set when a server attaches to a buffer
local function set_lsp_keymaps(args)
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
end

return {
  "neovim/nvim-lspconfig",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = {
    "mason-org/mason.nvim",
    "mason-org/mason-lspconfig.nvim",
  },
  config = function()
    -- The server inventory: Mason's servers, the system package manager's, and retired ones
    local servers = require "lsp_gates.servers"
    local typescript = require "lsp_gates.typescript"
    local terraform_trust = require "lsp_gates.terraform_trust"

    -- Each config run (for example :Lazy reload) starts a new session: the gates' notices show again
    terraform_trust.reset()
    typescript.reset()

    -- lsp.lua alone decides whether a system server runs. mason-lspconfig would otherwise enable any
    -- Mason-installed copy by name with lspconfig's defaults, skipping the gates below; Mason puts its
    -- bin dir first on PATH, so a Mason-only copy still runs through the gated loop.
    local not_auto_enabled = vim.list_extend(vim.tbl_keys(servers.system), servers.retired)
    table.sort(not_auto_enabled)

    local system_tsserver = typescript.system_tsserver()

    -- What a system server needs besides its command before it is enabled
    local activation_gates = {
      ts_ls = function()
        return system_tsserver ~= nil
      end,
    }

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
      -- LuaLS 3.19.1 loads a repo's .luarc.json runtime.plugin for either button of its trust
      -- prompt, so a null answer is the only real "no". This also declines its third-party library
      -- prompts.
      handlers = {
        ["window/showMessageRequest"] = function()
          return vim.NIL
        end,
      },
    })

    -- tsserver's automatic type acquisition runs npm to download @types packages, so it is off
    local ts_ls = { init_options = { disableAutomaticTypingAcquisition = true } }
    if system_tsserver then
      ts_ls.init_options.tsserver = { path = system_tsserver }
    else
      -- Never starts, not even through :lsp enable ts_ls: else ts_ls would load the workspace's
      -- TypeScript
      ts_ls.root_dir = typescript.refusing_root_dir()
    end
    vim.lsp.config("ts_ls", ts_ls)

    -- Remote schemas are never downloaded: the schema stores are off, and registerContentRequest has the
    -- server send $schema URLs to Neovim, which has no handler for them. on_init chains lspconfig's own
    -- on_init (it turns on formatting) instead of copying it, because a function is replaced, not
    -- merged. The empty-object params keep yaml-language-server from logging an ERROR on every start.
    local upstream_on_init = vim.lsp.config.yamlls and vim.lsp.config.yamlls.on_init
    vim.lsp.config("yamlls", {
      settings = {
        yaml = {
          schemaStore = { enable = false, url = "" },
          kubernetesCRDStore = { enable = false },
        },
      },
      on_init = function(client, init_result)
        if upstream_on_init then
          upstream_on_init(client, init_result)
        end
        client:notify("yaml/registerContentRequest", vim.empty_dict())
      end,
    })

    -- http(s) $schema URLs go to Neovim, which has no handler, so jsonls never downloads them; local
    -- schemas still work
    vim.lsp.config("jsonls", { init_options = { handledSchemaProtocols = { "file" } } })

    vim.lsp.config(terraform_trust.SERVER, { root_dir = terraform_trust.root_dir })

    -- A leftover Mason copy never starts, even with a bare :lsp enable
    for _, server in ipairs(servers.retired) do
      vim.lsp.config(server, { root_dir = function() end })
    end

    -- Configuration and activation are separate. Every system server gets its list cmd, so an
    -- explicit :lsp enable <name> for one of them never falls back to a repo's node_modules/.bin (a
    -- missing binary just fails to spawn). A bare :lsp enable enables every lspconfig server for the
    -- filetype, and some of those prefer node_modules/.bin (upstream behavior this config does not
    -- patch). Only the servers whose command is executable and whose gate (if any) passes are
    -- enabled, which keeps lsp.log free of spawn errors and makes vim.lsp.is_enabled reflect what is
    -- installed. Every vim.lsp.config call comes before mason_lspconfig.setup, because enabling
    -- re-fires FileType for open buffers.
    local enable = {}
    for server, cmd in pairs(servers.system) do
      vim.lsp.config(server, { cmd = cmd })
      local gate = activation_gates[server]
      if vim.fn.executable(cmd[1]) == 1 and (gate == nil or gate()) then
        table.insert(enable, server)
      end
    end

    local mason_lspconfig = require "mason-lspconfig"

    mason_lspconfig.setup {
      ensure_installed = servers.mason,
      automatic_enable = { exclude = not_auto_enabled },
    }

    vim.lsp.enable(enable)

    terraform_trust.create_command()

    vim.api.nvim_create_autocmd("LspAttach", { callback = set_lsp_keymaps })
  end,
}
