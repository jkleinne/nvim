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
    -- The server inventory: Mason's servers, the system package manager's, retired ones, and ones
    -- that never start
    local servers = require "lsp_gates.servers"
    local typescript = require "lsp_gates.typescript"
    local terraform_trust = require "lsp_gates.terraform_trust"

    -- Each config run (for example :Lazy reload) starts a new session: the gates' notices show again
    terraform_trust.reset()
    typescript.reset()

    -- lsp.lua alone decides whether a system server runs. mason-lspconfig would otherwise enable any
    -- Mason-installed copy by name with lspconfig's defaults, skipping the gates below; Mason puts its
    -- bin dir first on PATH, so a Mason-only copy still runs through the gated loop.
    local never_start = vim.list_extend(vim.list_extend({}, servers.retired), servers.never)
    local not_auto_enabled = vim.list_extend(vim.tbl_keys(servers.system), never_start)
    table.sort(not_auto_enabled)

    -- ts_ls's whole policy (lsp_gates.typescript): with a system TypeScript, ts_ls uses it, checks it
    -- again before each start, and then asks lspconfig's root_dir (taken here, before lsp.lua's own
    -- replaces it); without one, ts_ls never starts, not even through :lsp enable ts_ls (else it would
    -- load the workspace's TypeScript). Type acquisition (npm) is off either way.
    local upstream_ts = vim.lsp.config[typescript.SERVER]
    local ts_ls, ts_ls_enabled =
      typescript.ts_ls_config(typescript.system_tsserver(), upstream_ts and upstream_ts.root_dir)

    -- What a system server needs besides its command before it is enabled
    local activation_gates = {
      [typescript.SERVER] = function()
        return ts_ls_enabled
      end,
    }

    local capabilities = require("blink.cmp").get_lsp_capabilities()

    vim.lsp.config("*", {
      capabilities = capabilities,
    })

    vim.lsp.config("lua_ls", {
      -- LuaLS keeps the plugins a user approved in <logpath>/trusted and loads them without asking.
      -- A log dir this config owns starts empty, and the null answers below never add to it.
      cmd = { "lua-language-server", "--logpath=" .. vim.fn.stdpath "log" .. "/lua_ls" },
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
      -- prompts, and its auto-require and require-path prompts, so accepting an auto-require
      -- completion inserts only the name.
      handlers = {
        ["window/showMessageRequest"] = function()
          return vim.NIL
        end,
      },
    })

    vim.lsp.config(typescript.SERVER, ts_ls)

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

    -- A leftover Mason copy of a retired server, and a server that runs a repo's code
    -- (servers.never), never start, even with a bare :lsp enable
    for _, server in ipairs(never_start) do
      vim.lsp.config(server, { root_dir = function() end })
    end

    -- Configuration and activation are separate. Every system server gets its list cmd, so an
    -- explicit :lsp enable <name> for one of them never falls back to a repo's node_modules/.bin
    -- (Neovim refuses a list cmd whose binary is missing and logs it in lsp.log; nothing spawns). A
    -- bare :lsp enable enables every lspconfig server for the filetype, and some of those prefer
    -- node_modules/.bin (upstream behavior this config does not patch). Only the servers whose
    -- command is executable and whose gate (if any) passes are enabled, which keeps lsp.log free of
    -- those refusals and makes vim.lsp.is_enabled reflect what is installed. Every vim.lsp.config
    -- call comes before mason_lspconfig.setup, because enabling re-fires FileType for open buffers.
    -- When mason-lspconfig enables a Mason server it applies its own settings for it
    -- (mason-lspconfig.lsp.<name>), which would replace these; it has none for this config's Mason
    -- servers today.
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

    vim.api.nvim_create_autocmd("LspAttach", {
      group = vim.api.nvim_create_augroup("lsp_keymaps", { clear = true }),
      callback = set_lsp_keymaps,
    })
  end,
}
